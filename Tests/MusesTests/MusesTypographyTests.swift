import AppKit
import CoreText
import Testing
@testable import Muses

@MainActor
struct MusesTypographyTests {
    @Test("F3 resolves Latin, Chinese, and Japanese glyphs within the chosen families")
    func cascade() {
        for face in MusesTypography.Face.allCases {
            let base = MusesTypography.native(face, size: 34)
            #expect(base.fontName == face.rawValue)
            for text in ["A", "夜", "テ"] {
                let resolved = CTFontCreateForString(MusesTypography.native(face, size: 34, japanese: MusesTypography.hasKana(text)) as CTFont, text as CFString,
                                                    CFRange(location: 0, length: text.utf16.count))
                var character = text.utf16.first!
                var glyph: CGGlyph = 0
                #expect(CTFontGetGlyphsForCharacters(resolved, &character, &glyph, 1))
                #expect(glyph != 0)
                let name = CTFontCopyPostScriptName(resolved) as String
                if text == "夜" {
                    #expect(name.contains(face == .song || face == .strongSong ? "PingFang" : "Songti"))
                }
                if text == "テ" {
                    #expect(name.contains(face == .song || face == .strongSong ? "HiraginoSans" : "HiraMin"))
                }
            }
        }
    }

    @Test("Timeline fonts reuse descriptors at the original lyric sizes")
    func cachedFonts() {
        for size: CGFloat in [17, 22, 26, 34, 40] {
            let a = MusesTypography.native(.activeLyric, size: size)
            let b = MusesTypography.native(.activeLyric, size: size)
            #expect(a === b)
            #expect(a.pointSize == size)
        }
    }
}
