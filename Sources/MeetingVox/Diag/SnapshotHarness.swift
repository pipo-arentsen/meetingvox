import AppKit
import SwiftUI

/// One named view state to render (VS-1). Each unit of the main window adds
/// its states to `SnapshotStates.all`; the harness knows nothing about them.
struct SnapshotState {
    let name: String
    let width: CGFloat
    /// nil = as tall as the content needs.
    let height: CGFloat?
    let makeView: @MainActor (SnapshotContext) -> AnyView
}

/// What a state may draw from: the fixture environment and its sessions.
struct SnapshotContext {
    let env: SnapshotEnvironment
    let installed: SnapshotFixtures.Installed
}

/// The registry of states the `diag --mode snapshot` route renders.
enum SnapshotStates {
    @MainActor
    static var all: [SnapshotState] { [markdownMinuta, markdownFactoryTemplate] + SnapshotMainWindowStates.all + SnapshotDetailStates.all + SnapshotTabStates.all + SnapshotLibraryStates.all + SnapshotPillStates.all + SnapshotCalendarStates.all }

    /// A realistic minuta with its tasks table, as the Minuta tab shows it.
    @MainActor
    static let markdownMinuta = SnapshotState(name: "markdown-minuta", width: 760, height: nil) { _ in
        AnyView(MarkdownDocumentView(text: SnapshotFixtures.sampleMinutes).padding(24))
    }

    /// A factory template rendered as markdown (MD-5: real prompts parse and
    /// draw): the family one, which has a tasks table.
    @MainActor
    static let markdownFactoryTemplate = SnapshotState(name: "markdown-plantilla-familiar", width: 760, height: nil) { _ in
        AnyView(MarkdownDocumentView(text: FactoryTemplates.familiar.cuerpo).padding(24))
    }
}

/// Renders SwiftUI states to PNG without launching the app: no run loop
/// beyond short pumps, no coordinators, no Keychain, no network. An
/// offscreen borderless window hosts the view; nothing is ever shown, and the
/// process never becomes a regular app (`.prohibited`: no Dock icon, no menu
/// bar).
///
/// AppKit can return a blank bitmap for a view that was never displayed
/// (lists and split views especially), so every capture method is tried, in
/// order, and the first whose image is not blank (`SnapshotBlankCheck`) wins;
/// the method used is printed for each state.
@MainActor
enum SnapshotHarness {
    enum Method: String, CaseIterable {
        /// `cacheDisplay` on the window's theme frame (the window chrome too).
        case cacheDisplayThemeFrame = "cacheDisplay(theme frame)"
        /// `cacheDisplay` on the window's content view.
        case cacheDisplayContentView = "cacheDisplay(content view)"
        /// `CALayer.render(in:)` of the content view's layer tree.
        case layerRender = "layer.render"
        /// `cacheDisplay` on the hosting view alone (a subview).
        case cacheDisplayHostingView = "cacheDisplay(hosting view)"
        /// SwiftUI's own `ImageRenderer`, for pure-SwiftUI states only.
        case imageRenderer = "ImageRenderer"
    }

    struct Attempt {
        let method: Method
        let image: CGImage?
        var isBlank: Bool { image.map(SnapshotBlankCheck.isBlank) ?? true }
    }

    struct Result {
        let state: String
        let method: Method?
        let attempts: [Attempt]
        let pixelSize: CGSize?
        let file: URL?
    }

    /// Backing scale of the PNGs: 2x, as on the Retina screens the app runs on.
    static let scale: CGFloat = 2

    /// Idempotent: initializes AppKit for offscreen drawing without ever
    /// becoming a visible app.
    static func prepareApplication() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Renders every registered state (or only `only`) into `outDir`.
    static func run(
        states: [SnapshotState], context: SnapshotContext, outDir: URL, say: (String) -> Void
    ) throws -> [Result] {
        prepareApplication()
        var results: [Result] = []
        for state in states {
            let result = try render(state, context: context, outDir: outDir)
            results.append(result)
            let tried = result.attempts
                .map { "\($0.method.rawValue)=\($0.image == nil ? "no image" : ($0.isBlank ? "blank" : "ok"))" }
                .joined(separator: ", ")
            if let method = result.method, let size = result.pixelSize, let file = result.file {
                say("snapshot \(state.name): \(method.rawValue) · \(Int(size.width))x\(Int(size.height)) px · \(file.lastPathComponent)")
            } else {
                say("snapshot \(state.name): FAILED, every capture method was blank")
            }
            say("   tried: \(tried)")
        }
        return results
    }

    static func render(_ state: SnapshotState, context: SnapshotContext, outDir: URL) throws -> Result {
        let root = state.makeView(context)
            .frame(width: state.width, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: AnyView(root))
        let container = NSView()
        container.addSubview(hosting)

        // Size: the declared height, or what the content needs at this width.
        hosting.frame = NSRect(x: 0, y: 0, width: state.width, height: state.height ?? 100)
        hosting.layoutSubtreeIfNeeded()
        let height = state.height ?? max(1, ceil(hosting.fittingSize.height))
        let size = NSSize(width: state.width, height: height)
        container.frame = NSRect(origin: .zero, size: size)
        hosting.frame = container.bounds

        // Borderless and parked far off screen; never ordered front.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = container
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        defer { window.close() }
        container.wantsLayer = true
        settle(container)

        var attempts: [Attempt] = []
        var chosen: (Method, CGImage)?
        for method in Method.allCases {
            let image = capture(method, window: window, container: container, hosting: hosting, size: size, state: state, root: root)
            let attempt = Attempt(method: method, image: image)
            attempts.append(attempt)
            if chosen == nil, let image, !attempt.isBlank { chosen = (method, image) }
        }
        guard let (method, image) = chosen else {
            return Result(state: state.name, method: nil, attempts: attempts, pixelSize: nil, file: nil)
        }
        let file = outDir.appendingPathComponent("\(state.name).png")
        try png(image).write(to: file, options: .atomic)
        return Result(
            state: state.name, method: method, attempts: attempts,
            pixelSize: CGSize(width: image.width, height: image.height), file: file)
    }

    // MARK: - Capture methods

    /// SwiftUI lays out and draws on later run-loop turns: pump a few.
    private static func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }

    private static func capture(
        _ method: Method, window: NSWindow, container: NSView, hosting: NSView, size: NSSize,
        state: SnapshotState, root: some View
    ) -> CGImage? {
        switch method {
        case .cacheDisplayThemeFrame:
            guard let frame = container.superview else { return nil }
            return cacheDisplay(frame, size: size)
        case .cacheDisplayContentView:
            return cacheDisplay(container, size: size)
        case .layerRender:
            return layerRender(container, size: size)
        case .cacheDisplayHostingView:
            return cacheDisplay(hosting, size: size)
        case .imageRenderer:
            let renderer = ImageRenderer(content: root)
            renderer.scale = scale
            return renderer.cgImage
        }
    }

    private static func bitmap(size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size // points; the pixels are `scale` times more
        return rep
    }

    private static func cacheDisplay(_ view: NSView, size: NSSize) -> CGImage? {
        guard let rep = bitmap(size: size) else { return nil }
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        return rep.cgImage
    }

    private static func layerRender(_ view: NSView, size: NSSize) -> CGImage? {
        guard let layer = view.layer,
              let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    private static func png(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
