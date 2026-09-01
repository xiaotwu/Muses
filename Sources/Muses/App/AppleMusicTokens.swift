import CoreGraphics
import Foundation

/// Semantic spacing roles. Measured page geometry remains separate from
/// responsive breakpoints so constrained layouts can adapt without drifting.
enum AppleMusicSpacing {
    static let pageHorizontal: CGFloat = 40
    static let pageTop: CGFloat = 18
    static let browseTitleTop: CGFloat = 32
    /// Space from a page-level title/action row to its primary content.
    static let headerToPrimary: CGFloat = 28
    /// Space between controls that belong to the same content group.
    static let related: CGFloat = 20
    static let section: CGFloat = 34
    static let shelfContent: CGFloat = 13
    static let shelfItem: CGFloat = 18
    static let gridColumn: CGFloat = 20
    static let gridRow: CGFloat = 24
    static let chromeOuter: CGFloat = 8
    static let chromeInner: CGFloat = 12
    static let tableCell: CGFloat = 9
}

/// Measured 2026-08-20 from live `music.apple.com` CSS (`--keyColor`, page, type).
enum AppleMusicTokens {
    static let keyColorHex = "FA586A"
    static let keyColorRGB = (r: 250.0 / 255.0, g: 88.0 / 255.0, b: 106.0 / 255.0)
    static let darkPageRGB = (r: 31.0 / 255.0, g: 31.0 / 255.0, b: 31.0 / 255.0)
    static let lightPageRGB = (r: 1.0, g: 1.0, b: 1.0)
    static let pageTitleSize: CGFloat = 34
    static let sectionTitleSize: CGFloat = 22
    static let sidebarWidth: CGFloat = 244
    static let sidebarCorner: CGFloat = 20
    static let sidebarInset: CGFloat = AppleMusicSpacing.chromeOuter
    static let cardCorner: CGFloat = 12
    static let editorialWidth: CGFloat = 540
    static let editorialHeight: CGFloat = 309
    static let editorialAspect: CGFloat = editorialWidth / editorialHeight
    static let contentPaddingX: CGFloat = AppleMusicSpacing.pageHorizontal
    static let scrollBottomInset: CGFloat = OverlayChromeMetrics.scrollBottomInset
    static let navItemHeight: CGFloat = 34
    static let playerBottomMargin: CGFloat = 20
    static let playerHorizontalMargin: CGFloat = 16
    static let capsuleWidth: CGFloat = 668
    static let capsuleHeight: CGFloat = 56
    static let capsuleCorner: CGFloat = 1000
    static let collectionDeckRoomyCardWidth: CGFloat = 156
    static let collectionDeckCompactCardWidth: CGFloat = 126
    static let collectionDeckRoomyFooterHeight: CGFloat = 56
    static let collectionDeckCompactFooterHeight: CGFloat = 48
    static let collectionDeckRoomySpread: CGFloat = 86
    static let collectionDeckMediumSpread: CGFloat = 78
    static let collectionDeckCompactSpread: CGFloat = 72
    static let collectionDeckWideBreakpoint: CGFloat = 810
    static let collectionDeckCompactBreakpoint: CGFloat = 620
    static let collectionDeckCompactHeight: CGFloat = 680
    static let collectionDeckHoverLift: CGFloat = 12
    static let collectionDeckExpansionThreshold: CGFloat = 48
    static let collectionDeckScrubberHeight: CGFloat = 52
    static let collectionDeckHandleHeight: CGFloat = 44
    static let trackArtworkSize: CGFloat = 38
}

/// Live music.apple.com chrome (2026-08-20 screenshot), not the Sidra top-bar shell.
enum AppleMusicChrome {
    static let primaryNavInSidebar = true
    static let playerIsFloatingCapsule = true
    static let editorialAspect: CGFloat = AppleMusicTokens.editorialAspect
    static let selectedNavUsesAccent = true
}

enum LibraryChromePolicy {
    static let sidebarIsPermanent = true

    /// Music Inbox was a revisit/triage queue. Hidden from chrome; tables remain.
    static let showsInbox = false
}

enum ChromeGlyphStyle {
    static let selectedGlowRadius: CGFloat = 0
    static let selectedUsesAccent = true
}

enum SearchChromePolicy {
    static let presentsAsFloatingGlass = true
    static let panelMaxWidth: CGFloat = 680
    static let panelCorner: CGFloat = 18
    static let addMusicSystemImage = "plus"

    static func topResult(from titles: [String], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let prefix = titles.first(where: { $0.range(of: q, options: [.caseInsensitive, .anchored]) != nil }) {
            return prefix
        }
        return titles.first
    }
}

/// The Search destination is one auxiliary SwiftUI window sharing the app's
/// service graph. It never replaces or renames the main browsing window.
enum SearchWindowPolicy {
    static let sceneID = "search"
    static let defaultWidth: CGFloat = 680
    static let defaultHeight: CGFloat = 620
    static let minimumWidth: CGFloat = 600
    static let minimumHeight: CGFloat = 520
    static let screenEdgeInset: CGFloat = 32
    static let draggableHeaderHeight: CGFloat = 52
    static let contentInset: CGFloat = 24
    static let controlHeight: CGFloat = 44
    static let sourceSegmentHeight: CGFloat = 34
    static let resultRowHeight: CGFloat = 68
    static let isSingleInstance = true
    static let closesOnEscape = true
}

/// Open Design measurements for the All Playlists hero-card overview.
enum PlaylistOverviewMetrics {
    static let minimumColumnWidth: CGFloat = 216
    static let maximumColumnWidth: CGFloat = 220
    static let cardWidth: CGFloat = 218
    static let artworkHeight: CGFloat = 188
    static let footerHeight: CGFloat = 104
    static let cardHeight: CGFloat = artworkHeight + footerHeight
    static let cornerRadius: CGFloat = 16
    static let columnSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 30
    static let hoverLift: CGFloat = 5
    static let pressedScale: CGFloat = 0.992
}

enum DockLyricsPolicy {
    enum Action: Equatable {
        case toggleDrawer
        case toggleLyricsFocus
    }

    static func action(nowPlayingOpen: Bool) -> Action {
        nowPlayingOpen ? .toggleLyricsFocus : .toggleDrawer
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

enum HomePagePolicy {
    static let topPicksUsePortraitCards = true
    static let additionalShelvesUseSquareCards = true
}

enum NewPagePolicy {
    static let featuredUsesLandscapeEditorialCards = true
    static let bestNewSongsUsesAdaptiveMatrix = true
    static let compactSongColumnMinimum: CGFloat = 280
}

enum SettingsChromePolicy {
    static func showsAccount(isPresented: Bool) -> Bool { isPresented }
    static func allowsUnderlyingInteraction(isPresented: Bool) -> Bool { !isPresented }
    static func allowsBrowseInteraction(isPresented: Bool) -> Bool {
        allowsUnderlyingInteraction(isPresented: isPresented)
    }
    static let dismissesTransientOverlaysOnPresentation = true
    static let presentsAsFloatingGlass = true
    static let stickyTitle = true
    static let usesLiquidGlass = true
}

enum PlayerLayoutPolicy {
    /// Capsule floats over browsing content; it does not reserve a layout row.
    static let isWindowOverlay = true
}

enum ProductionPlaybackPolicy {
    static let isYouTubeOnly = true
}

enum PlayerTransportPolicy {
    static let leadingClusterIsTransport = true
    static let identityIsCentered = true
}

enum PlayerControlPolicy {
    /// Volume has one discoverable entry in the trailing chrome. The popover
    /// owns the slider so the identity area never duplicates it or clips.
    static let usesSingleVolumeEntry = true
    /// YouTube video overlay keeps `YouTubeMark`. Play/pause never uses it.
    static let usesYouTubeMark = true
    /// Now Playing opens only from the current artwork, not a duplicate expand
    /// glyph or another PlayerBar action.
    static let hidesExpandControl = true
    static let nowPlayingOpensFromArtwork = true
}

enum QueueChromePolicy {
    static let isIntegratedTrailingPane = true
    static let isDetachedRoundedCard = false
    static let width: CGFloat = 360
}

enum NowPlayingChromePolicy {
    static let coversWindow = true
    static let hidesDock = true
    static func canOpen(hasTrack: Bool) -> Bool { hasTrack }
}

enum SidebarGlassPolicy {
    static let usesLiquidGlass = true
    static let touchesTopLeadingAndBottomEdges = true
}

enum StationCardHitPolicy {
    static let clipsOverflow = true
}

enum TrafficLightsPolicy {
    static let livesInSidebar = true
    /// Standard buttons stay in AppKit's titlebar hierarchy. SwiftUI only
    /// reserves a transparent region beneath them.
    static let reparentsStandardButtons = false
    static let usesDelayedLayoutRetries = false
}

enum WindowChromeMetrics {
    /// Live pane is flush to the window's top, bottom, and leading edges.
    /// The 8pt Apple Music Web measurement remains `AppleMusicTokens.sidebarInset`.
    static let sidebarOuterInset: CGFloat = 0
    static let trafficLightClearanceWidth: CGFloat = 72
    /// Matches the native titlebar cluster and the 28pt chrome hit target.
    static let trafficLightClearanceHeight: CGFloat = 28
    /// Native AppKit buttons stay where `NSWindow` places them. SwiftUI only
    /// reserves this transparent pad so wordmark/nav cannot collide.
    static let trafficLightTopInset: CGFloat = 0
    static let minimumWidth: CGFloat = 840
    static let minimumHeight: CGFloat = 600
}

enum PlaylistListPolicy {
    static func minListHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat? { nil }
}

enum SidebarRowHitPolicy {
    static let usesFullRowHitTarget = true
}

enum SongGridMetrics {
    static let minCard: CGFloat = 148
    static let maxCard: CGFloat = 176
    static let spacing: CGFloat = 18
    /// Portrait Made-for-You tile (width / height).
    static let aspect: CGFloat = 3.0 / 4.0
}

enum OverlayChromeMetrics {
    static let scrollBottomInset: CGFloat = 96
}
