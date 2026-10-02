import AppKit
import SwiftUI

/// The main window's colours, from the approved mockup: a light and a dark
/// value each, resolved by the view's appearance (so the headless snapshots,
/// which pin `.aqua`, and the live window agree).
enum MainPalette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let window = dynamic(light: 0xFFFFFF, dark: 0x1C2026)
    static let side = dynamic(light: 0xEDEFF2, dark: 0x171A1F)
    static let selection = dynamic(light: 0xD9E3F7, dark: 0x26375A)
    static let line = dynamic(light: 0xD8DDE3, dark: 0x2A3038)
    static let chrome = dynamic(light: 0xE6E8EB, dark: 0x23272D)
    static let sunken = dynamic(light: 0xE9ECF0, dark: 0x1F242A)
    static let muted = dynamic(light: 0x58606B, dark: 0x99A2AD)
    static let accent = dynamic(light: 0x2350B5, dark: 0x7C9DF2)
    static let accentBackground = dynamic(light: 0xE4EBFA, dark: 0x1E2A45)
    static let recording = dynamic(light: 0xD6332A, dark: 0xFF6259)
    static let error = dynamic(light: 0xB8283A, dark: 0xF06B7C)
    static let errorBackground = dynamic(light: 0xF9E6E9, dark: 0x3A1A21)
    static let ok = dynamic(light: 0x1F7A52, dark: 0x5CCB94)
    static let high = dynamic(light: 0xB95A12, dark: 0xF09A55)

    /// The dot next to an ámbito (sidebar, rows).
    static func dot(for ambito: Ambito?) -> Color {
        switch ambito {
        case .trabajo: accent
        case .profesional: ok
        case .personal: high
        case nil: line
        }
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}
