import Testing

@testable import MeetingVox

/// A view that AppKit failed to draw offscreen comes out as a uniform image
/// (transparent, or just the window background). The harness must notice and
/// retry another capture method, so "blank" is a pure decision over pixels.
@Suite("SnapshotBlankCheck")
struct SnapshotBlankCheckTests {
    /// An RGBA8 canvas filled with one colour; `bytesPerRow` may exceed
    /// `width * 4` (AppKit pads rows), the padding filled with `padding`.
    private struct Canvas {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
             rowPadding: Int = 0, padding: UInt8 = 0) {
            self.width = width
            self.height = height
            bytesPerRow = width * 4 + rowPadding
            bytes = [UInt8](repeating: padding, count: bytesPerRow * height)
            for y in 0..<height {
                for x in 0..<width { set(x, y, fill) }
            }
        }

        mutating func set(_ x: Int, _ y: Int, _ color: (UInt8, UInt8, UInt8, UInt8)) {
            let i = y * bytesPerRow + x * 4
            bytes[i] = color.0; bytes[i + 1] = color.1; bytes[i + 2] = color.2; bytes[i + 3] = color.3
        }

        mutating func fillRect(x0: Int, y0: Int, x1: Int, y1: Int, _ color: (UInt8, UInt8, UInt8, UInt8)) {
            for y in y0..<y1 { for x in x0..<x1 { set(x, y, color) } }
        }

        var isBlank: Bool {
            SnapshotBlankCheck.isBlank(rgba: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }

    @Test func aUniformWhiteImageIsBlank() {
        #expect(Canvas(width: 200, height: 100).isBlank)
    }

    @Test func aFullyTransparentImageIsBlank() {
        #expect(Canvas(width: 200, height: 100, fill: (0, 0, 0, 0)).isBlank)
    }

    @Test func aUniformNonWhiteBackgroundIsBlankToo() {
        // A window background with nothing drawn on it.
        #expect(Canvas(width: 200, height: 100, fill: (236, 236, 236, 255)).isBlank)
    }

    @Test func anImageWithNoPixelsIsBlank() {
        #expect(SnapshotBlankCheck.isBlank(rgba: [], width: 0, height: 0, bytesPerRow: 0))
        #expect(SnapshotBlankCheck.isBlank(rgba: [], width: 10, height: 0, bytesPerRow: 40))
    }

    @Test func aBlockOfTextLikeInkIsNotBlank() {
        var canvas = Canvas(width: 200, height: 100)
        canvas.fillRect(x0: 20, y0: 20, x1: 120, y1: 30, (30, 30, 30, 255)) // 5 % of the pixels
        #expect(!canvas.isBlank)
    }

    @Test func aSinglePixelOfNoiseIsStillBlank() {
        var canvas = Canvas(width: 200, height: 100)
        canvas.set(5, 5, (0, 0, 0, 255)) // 0.005 %
        #expect(canvas.isBlank)
    }

    @Test func aSparseButRealDrawingIsNotBlank() {
        var canvas = Canvas(width: 200, height: 100)
        canvas.fillRect(x0: 0, y0: 0, x1: 100, y1: 2, (0, 0, 0, 255)) // 1 % of the pixels
        #expect(!canvas.isBlank)
    }

    @Test func aHalfAndHalfImageIsNotBlank() {
        // A sidebar tone next to a white column: uniform halves are content.
        var canvas = Canvas(width: 200, height: 100)
        canvas.fillRect(x0: 0, y0: 0, x1: 100, y1: 100, (200, 205, 215, 255))
        #expect(!canvas.isBlank)
    }

    @Test func nearlyIdenticalColoursCountAsTheSameColour() {
        // Anti-aliasing noise of a couple of levels is not content.
        var canvas = Canvas(width: 200, height: 100, fill: (250, 250, 250, 255))
        canvas.fillRect(x0: 0, y0: 0, x1: 200, y1: 50, (252, 251, 250, 255))
        #expect(canvas.isBlank)
    }

    @Test func rowPaddingBytesAreNotPixels() {
        // 200 x 100 white, with 64 garbage bytes at the end of every row.
        #expect(Canvas(width: 200, height: 100, rowPadding: 64, padding: 7).isBlank)
        var canvas = Canvas(width: 200, height: 100, rowPadding: 64, padding: 7)
        canvas.fillRect(x0: 10, y0: 10, x1: 110, y1: 20, (0, 0, 0, 255))
        #expect(!canvas.isBlank)
    }

    @Test func aBufferShorterThanItsDeclaredSizeIsBlank() {
        // Defensive: a malformed capture must not crash or count as content.
        #expect(SnapshotBlankCheck.isBlank(rgba: [255, 255, 255, 255], width: 200, height: 100, bytesPerRow: 800))
    }
}
