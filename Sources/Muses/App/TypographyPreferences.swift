import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TypographyPreferences {
    static let shared = TypographyPreferences()
    var size: InterfaceTextSize {
        didSet { defaults.set(size.rawValue, forKey: PrefKey.interfaceTextSize) }
    }
    var family: String {
        didSet { defaults.set(family, forKey: PrefKey.interfaceFontFamily) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        size = InterfaceTextSize(rawValue: defaults.string(forKey: PrefKey.interfaceTextSize) ?? "") ?? .standard
        family = defaults.string(forKey: PrefKey.interfaceFontFamily) ?? ""
    }
}

enum InterfaceTextSize: String, CaseIterable, Identifiable {
    case small, standard, large
    var id: String { rawValue }
    var scale: CGFloat {
        switch self { case .small: 0.9; case .standard: 1; case .large: 1.15 }
    }
    @MainActor var label: String {
        switch self {
        case .small: tr("Small", "小")
        case .standard: tr("Standard", "标准")
        case .large: tr("Large", "大")
        }
    }
}

@MainActor
extension MusesTypography {
    private static var customFonts: [String: NSFont] = [:]

    static func preferredNative(size: CGFloat, emphasized: Bool = false) -> NSFont? {
        let family = TypographyPreferences.shared.family
        guard !family.isEmpty else { return nil }
        let key = "\(family):\(size):\(emphasized)"
        if let font = customFonts[key] { return font }
        guard let font = NSFontManager.shared.font(withFamily: family,
            traits: emphasized ? .boldFontMask : [], weight: emphasized ? 9 : 5, size: size)
            ?? NSFont(name: family, size: size) else { return nil }
        if customFonts.count > 300 { customFonts.removeAll() }
        customFonts[key] = font
        return font
    }

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let scaled = size * TypographyPreferences.shared.size.scale
        if design != .monospaced, let font = preferredNative(size: scaled, emphasized: weight != .regular && weight != .light) {
            return Font(font).weight(weight)
        }
        return .system(size: scaled, weight: weight, design: design)
    }

    static var largeTitle: Font { system(size: 26) }
    static var title: Font { system(size: 22) }
    static var title2: Font { system(size: 17) }
    static var title3: Font { system(size: 15) }
    static var headline: Font { system(size: 13, weight: .semibold) }
    static var body: Font { system(size: 13) }
    static var callout: Font { system(size: 12) }
    static var subheadline: Font { system(size: 11) }
    static var footnote: Font { system(size: 10) }
    static var caption: Font { system(size: 10) }
    static var caption2: Font { system(size: 10) }
}
