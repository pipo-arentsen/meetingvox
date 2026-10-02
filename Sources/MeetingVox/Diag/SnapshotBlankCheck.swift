import CoreGraphics
import Foundation

/// Decides whether a captured image has anything drawn on it. AppKit can
/// hand back a uniform image (transparent, or only the window background)
/// when a view was not laid out or not drawn offscreen; the snapshot harness
/// then retries with another capture method. Pure over the pixels so the
/// decision is unit-tested; the harness only converts its bitmap to RGBA.
enum SnapshotBlankCheck {
    /// Fraction of pixels that must differ from the dominant colour for the
    /// image to count as content. One stray pixel is noise; a thin rule or a
    /// line of text is not.
    static let inkThreshold = 0.002
    /// Per-channel distance (0...255) under which two colours are the same:
    /// anti-aliasing and gradients of a flat background stay "blank".
    static let colorTolerance = 12
    /// Bits dropped per channel when looking for the dominant colour.
    private static let bucketShift = 4

    /// - Parameters:
    ///   - rgba: 8-bit RGBA, row-major, `bytesPerRow` apart (row padding is
    ///     ignored).
    /// - Returns: true for an empty image, a buffer too short for its
    ///   declared size, or one where almost every pixel is the dominant
    ///   colour.
    static func isBlank(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> Bool {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              rgba.count >= (height - 1) * bytesPerRow + width * 4
        else { return true }

        // Pass 1: the dominant colour, by coarse bucket; a real pixel of the
        // winning bucket stands in for it.
        var counts: [UInt32: Int] = [:]
        var representative: [UInt32: (Int, Int, Int, Int)] = [:]
        for y in 0..<height {
            var i = y * bytesPerRow
            for _ in 0..<width {
                let (r, g, b, a) = (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
                let key = UInt32(r >> bucketShift) << 24 | UInt32(g >> bucketShift) << 16
                    | UInt32(b >> bucketShift) << 8 | UInt32(a >> bucketShift)
                counts[key, default: 0] += 1
                if representative[key] == nil { representative[key] = (r, g, b, a) }
                i += 4
            }
        }
        guard let dominant = counts.max(by: { $0.value < $1.value })?.key,
              let base = representative[dominant]
        else { return true }

        // Pass 2: how many pixels are genuinely different from it.
        var different = 0
        for y in 0..<height {
            var i = y * bytesPerRow
            for _ in 0..<width {
                if abs(Int(rgba[i]) - base.0) > colorTolerance || abs(Int(rgba[i + 1]) - base.1) > colorTolerance
                    || abs(Int(rgba[i + 2]) - base.2) > colorTolerance || abs(Int(rgba[i + 3]) - base.3) > colorTolerance
                { different += 1 }
                i += 4
            }
        }
        return Double(different) / Double(width * height) < inkThreshold
    }
}

extension SnapshotBlankCheck {
    /// Draws `image` into an 8-bit premultiplied RGBA bitmap and applies the
    /// pure check. The conversion is the only non-pure step; the pixel
    /// decision stays in `isBlank(rgba:width:height:bytesPerRow:)`.
    static func isBlank(_ image: CGImage) -> Bool {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0 else { return true }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return !drawn || isBlank(rgba: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}
