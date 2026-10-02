import AppKit

/// The app's feather glyph, shared by the menu-bar item and the main
/// window's title strip. Pure: no config, Keychain or home access, so the
/// snapshot-pure `UI/Main` may use it.
enum AppGlyph {
    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it: true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    /// The feather as an `NSImage` of `side` points (the menu bar uses 16:
    /// status icons are nominally 18 pt tall).
    static func feather(side: CGFloat = 16) -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        return image
    }
}
