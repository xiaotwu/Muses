import SwiftUI

/// Stroke-style chrome icon: semibold monochrome SF Symbol, 70% idle, full
/// primary + restrained glow when selected. Used on the top bar, Library
/// sidebar, and player dock.
struct ChromeGlyph: View {
    let systemName: String
    var selected: Bool = false
    var size: CGFloat = 14
    var hit: CGFloat = 28

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(selected && ChromeGlyphStyle.selectedUsesAccent
                             ? BrandColors.magenta : BrandColors.textPrimary)
            .opacity(selected ? 1.0 : (isHovered ? 0.95 : 0.7))
            .scaleEffect(isHovered && !reduceMotion ? 1.06 : 1.0)
            .offset(y: isHovered && !reduceMotion ? -1 : 0)
            .frame(width: max(28, hit), height: max(28, hit))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(MusesMotion.hoverAnimation(reduceMotion: reduceMotion), value: isHovered)
    }
}

enum AppTopTab: String, Hashable, CaseIterable {
    case home, new, library

    var label: String {
        switch self {
        case .home: tr("Home", "首页")
        case .new: tr("New", "新发现")
        case .library: tr("Library", "资料库")
        }
    }

    static func from(_ section: SidebarSection) -> AppTopTab {
        switch section {
        case .home, .search: return .home
        case .new: return .new
        default: return .library
        }
    }
}

extension SidebarSection {
    var isLibrary: Bool {
        switch self {
        case .songs, .playlists, .history, .inbox, .albums, .artists:
            return true
        default:
            return false
        }
    }
}
