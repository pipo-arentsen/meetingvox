// Generates the MeetingVox app icon as an .iconset directory.
//
//   swift Packaging/Icon/make-icon.swift <output.iconset>
//   iconutil -c icns <output.iconset> -o AppIcon.icns
//
// Scripts/build-app.sh runs both at build time; the result is not committed.
// There is no Xcode on the build machine (so no actool / asset catalog), and a
// committed binary would drift from this source.
//
// The glyph is the same Lucide feather used by the menu-bar item. It is a copy
// of `MenuBarController.featherSVG` (Sources/MeetingVox/UI/MenuBarController.swift);
// keep both in sync if the artwork changes.

import AppKit

let featherPaths = """
<path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
<path d="M16 8 2 22"/>\
<path d="M17.5 15H9"/>
"""

/// White glyph (the menu-bar SVG uses `currentColor`, which has no meaning here).
let featherSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
fill="none" stroke="#FFFFFF" stroke-width="1.5" stroke-linecap="round" \
stroke-linejoin="round">\(featherPaths)</svg>
"""

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

guard let glyph = NSImage(data: Data(featherSVG.utf8)) else {
    FileHandle.standardError.write(Data("make-icon: cannot decode the feather SVG\n".utf8))
    exit(1)
}

/// One square PNG of `pixels` x `pixels`, drawn at that exact pixel size
/// (no backing-scale surprises, whatever screen the build runs on).
func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    // macOS icon grid: the tile fills ~80 % of the canvas, corner radius ~22.5 % of the tile.
    let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(
        starting: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        ending: NSColor(srgbRed: 0.55, green: 0.22, blue: 0.85, alpha: 1)
    )?.draw(in: path, angle: -60)

    let glyphSide = tile.width * 0.56
    let glyphRect = NSRect(
        x: tile.midX - glyphSide / 2, y: tile.midY - glyphSide / 2,
        width: glyphSide, height: glyphSide)
    glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)

    return rep.representation(using: .png, properties: [:])
}

// (point size, scale) pairs iconutil expects.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

do {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    for (points, scale) in variants {
        guard let png = renderPNG(pixels: points * scale) else {
            FileHandle.standardError.write(Data("make-icon: render failed at \(points)@\(scale)x\n".utf8))
            exit(1)
        }
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try png.write(to: outputDir.appendingPathComponent(name))
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
