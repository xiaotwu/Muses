import AppKit
import CoreText
import Testing
@testable import Muses

@Suite("Brand typography")
@MainActor
struct BrandFontTests {
    @Test("bundled Island Moments registers and covers the complete product wordmark")
    func bundledWordmark() throws {
        _ = try #require(MusesResources.islandMomentsFontURL)
        FontLoader.registerBrandFont()
        let font = try #require(NSFont(name: "IslandMoments-Regular", size: 36))
        #expect(font.fontName == "IslandMoments-Regular")
        let characters = Array(BrandFont.wordmark.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count))
        #expect(glyphs.allSatisfy { $0 != 0 })
        let size = NSAttributedString(string: BrandFont.wordmark, attributes: [.font: font]).size()
        #expect(size.width < 300)
    }
}
