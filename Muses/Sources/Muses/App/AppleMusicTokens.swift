import CoreGraphics
import Foundation

/// Measured 2026-08-20 from live `music.apple.com` CSS (`--keyColor`, page, type).
enum AppleMusicTokens {
    static let keyColorHex = "FA586A"
    static let keyColorRGB = (r: 250.0 / 255.0, g: 88.0 / 255.0, b: 106.0 / 255.0)
    static let darkPageRGB = (r: 31.0 / 255.0, g: 31.0 / 255.0, b: 31.0 / 255.0)
    static let lightPageRGB = (r: 1.0, g: 1.0, b: 1.0)
    static let pageTitleSize: CGFloat = 34
    static let sectionTitleSize: CGFloat = 22
    static let sidebarWidth: CGFloat = 250
    static let cardCorner: CGFloat = 8
}

enum LibraryChromePolicy {
    static func showsSidebar(section: SidebarSection, collapsed: Bool) -> Bool {
        !collapsed
    }
}

enum ChromeGlyphStyle {
    static let selectedGlowRadius: CGFloat = 0
    static let selectedUsesAccent = true
}

enum SearchChromePolicy {
    static func occupiesContent(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func topResult(from titles: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let prefix = titles.first(where: { $0.range(of: q, options: [.caseInsensitive, .anchored]) != nil }) {
            return prefix
        }
        return titles.first
    }
}

enum DockLyricsPolicy {
    enum Action: Equatable {
        case openNowPlaying
        case toggleLyricsFocus
    }

    static func action(nowPlayingOpen: Bool) -> Action {
        nowPlayingOpen ? .toggleLyricsFocus : .openNowPlaying
    }
}

enum TopPicksResolver {
    static func picks(hero: DiscoveryItem?,
                      mixed: [DiscoveryItem],
                      recent: [DiscoveryItem],
                      max: Int = 3) -> [DiscoveryItem] {
        var out: [DiscoveryItem] = []
        var seen = Set<String>()
        func add(_ item: DiscoveryItem) {
            guard out.count < max, seen.insert(item.id).inserted else { return }
            out.append(item)
        }
        if let hero { add(hero) }
        mixed.forEach(add)
        recent.forEach(add)
        return out
    }
}

enum NewFeaturedResolver {
    static func featured(from items: [DiscoveryItem]) -> DiscoveryItem? {
        items.first
    }
}

enum SettingsChromePolicy {
    static func showsAccount(isPresented: Bool) -> Bool { isPresented }
}
