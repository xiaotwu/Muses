import Testing
import AppKit
@testable import Muses

@Suite("AlbumArtworkExtractor")
struct AlbumArtworkExtractorTests {
    @Test("extracts up to 3 dominant colors from a solid image")
    func solidColor() {
        let img = NSImage(swatch: NSColor(red: 0.9, green: 0.1, blue: 0.9, alpha: 1),
                         size: NSSize(width: 64, height: 64))
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        #expect(!colors.isEmpty)
        #expect(colors.count <= 3)
        let first = colors[0]
        #expect(first.redComponent > 0.7)
        #expect(first.blueComponent > 0.7)
    }

    @Test("returns empty for zero-size image")
    func zeroSize() {
        let img = NSImage(size: NSSize(width: 0, height: 0))
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        #expect(colors.isEmpty)
    }

    @Test("respects requested count")
    func countCap() {
        let img = NSImage(swatch: NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                          size: NSSize(width: 32, height: 32))
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 1)
        #expect(colors.count == 1)
    }
}

extension NSImage {
    convenience init(swatch color: NSColor, size: NSSize) {
        self.init(size: size)
        lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        unlockFocus()
    }
}
