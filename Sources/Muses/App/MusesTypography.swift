import AppKit
import SwiftUI

/// Approved F3: editorial serif headings/lyrics, humanist song text, native chrome.
/// Cascade descriptors keep Chinese and Japanese in the same semantic family.
@MainActor
enum MusesTypography {
    enum Face: String, CaseIterable {
        case heading = "Georgia-Bold"
        case lyric = "Georgia-Italic"
        case activeLyric = "Georgia-BoldItalic"
        case song = "AvenirNext-Regular"
        case strongSong = "AvenirNext-DemiBold"

        var cascadeNames: [String] {
            switch self {
            case .heading, .activeLyric:
                return ["STSongti-SC-Bold", "STSongti-TC-Bold", "HiraMinProN-W6"]
            case .lyric:
                return ["STSongti-SC-Regular", "STSongti-TC-Regular", "HiraMinProN-W3"]
            case .song:
                return ["PingFangSC-Regular", "PingFangTC-Regular", "HiraginoSans-W3"]
            case .strongSong:
                return ["PingFangSC-Medium", "PingFangTC-Medium", "HiraginoSans-W5"]
            }
        }
    }

    private struct Key: Hashable {
        let face: Face
        let size: CGFloat
        let japanese: Bool
    }

    // Construct descriptors once, outside SwiftUI bodies and lyric timelines.
    private static let fonts: [Key: NSFont] = {
        let sizes: [CGFloat] = [11, 12, 12.5, 13, 14, 15, 17, 18, 20, 22, 26, 34, 40]
        var result: [Key: NSFont] = [:]
        for face in Face.allCases {
            for size in sizes {
                for japanese in [false, true] {
                    let names = japanese
                        ? [face.cascadeNames.last!] + face.cascadeNames.dropLast()
                        : face.cascadeNames
                    let descriptor = NSFontDescriptor(fontAttributes: [
                        .name: face.rawValue,
                        .cascadeList: names.map { NSFontDescriptor(name: $0, size: size) }
                    ])
                    result[Key(face: face, size: size, japanese: japanese)] = NSFont(descriptor: descriptor, size: size)
                        ?? NSFont.systemFont(ofSize: size)
                }
            }
        }
        return result
    }()

    static func native(_ face: Face, size: CGFloat, japanese: Bool = false) -> NSFont {
        fonts[Key(face: face, size: size, japanese: japanese)] ?? NSFont.systemFont(ofSize: size)
    }

    static let pageTitle = Font(native(.heading, size: 34))
    static let sectionTitle = Font(native(.heading, size: 22))
    static let settingsTitle = sectionTitle

    static func song(size: CGFloat = 14, emphasized: Bool = false, text: String = "") -> Font {
        Font(native(emphasized ? .strongSong : .song, size: size, japanese: hasKana(text)))
    }

    static func lyric(size: CGFloat, current: Bool, text: String = "") -> Font {
        Font(native(current ? .activeLyric : .lyric, size: size, japanese: hasKana(text)))
    }
    static func heading(_ text: String, size: CGFloat = 34) -> Font {
        Font(native(.heading, size: size, japanese: hasKana(text)))
    }

    static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value)
                || (0x1B000...0x1B16F).contains($0.value)
        }
    }
}
