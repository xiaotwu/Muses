import AppKit
import SwiftData
import SwiftUI

/// YouTube Music Home information architecture in Muses' native visual system.
struct HomeView: View {
    @Environment(LibraryService.self) var library
    @Environment(PlaybackService.self) var playback
    @Environment(YouTubeSearchService.self) var youTubeSearch
    @Environment(HomeDiscoveryService.self) var discovery
    @Environment(WebHomeSessionController.self) var webHome
    @Environment(FocusService.self) var focus
    @Environment(YouTubeAccountService.self) var youTubeAccount
    @Environment(GlobalSearchService.self) var globalSearch
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) var imports: [YouTubeImport]

    @State var recentlyPlayed: [TrackSnapshot] = []
    @State var fallbackEntries: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State var fallbackLoading = false
    @State var fallbackError: String?
    @State var interactionError: String?
    @State var fallbackTask: Task<Void, Never>?
    @State var accountChangeTask: Task<Void, Never>?

    var activeImports: [YouTubeImport] {
        imports.filter { $0.deletedAt == nil }
    }

    var supportedRecent: [TrackSnapshot] {
        recentlyPlayed.filter { !$0.youTubeId.isEmpty }
    }

    var remoteTopPickItems: [DiscoveryItem] {
        let remote = discovery.sections.flatMap(\.items).filter(isPlayableDiscoveryItem)
        let fallback = fallbackEntries.map {
            DiscoveryItem.youTube(YouTubeDiscoveryCard(entry: $0))
        }
        return remote.isEmpty ? fallback : remote
    }

    var topPickItems: [DiscoveryItem] {
        TopPicksResolver.picks(
            hero: nil,
            mixed: remoteTopPickItems,
            recent: supportedRecent.map(DiscoveryItem.track),
            max: 6
        )
    }

    var firstVisibleDiscoverySectionID: String? {
        discovery.sections.first { !$0.items.filter(isPlayableDiscoveryItem).isEmpty }?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleMusicSpacing.section) {
                Text(tr("Home", "首页"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)

                homeSourceStatus

                moodChips

                if discovery.isShowingStale {
                    staleBanner
                }

                if shouldShowWebRecovery {
                    webRecoveryBanner
                }

                if !youTubeAccount.isConnected {
                    guestBanner
                } else if youTubeAccount.channelState.errorMessage != nil
                            || youTubeAccount.playlistsState.errorMessage != nil
                            || youTubeAccount.subscriptionsState.errorMessage != nil
                            || youTubeAccount.likedVideosState.errorMessage != nil {
                    accountRefreshFailureBanner
                }

                if let interactionError {
                    DiscoveryFailureStrip(
                        message: interactionError,
                        onRetry: {
                            self.interactionError = nil
                            discovery.reload()
                        }
                    )
                    .padding(.horizontal, AppleMusicTokens.contentPaddingX)
                }

                if focus.isActive {
                    focusState
                } else {
                    discoveryShelves
                }

                if !activeImports.isEmpty {
                    importedPlaylistsShelf
                }
            }
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, AppleMusicTokens.scrollBottomInset)
        }
        .background(BrowseBackground())
        .onAppear {
            refreshRecentlyPlayed()
            if discovery.isEnabled {
                discovery.load()
            } else {
                loadFallback()
            }
        }
        .onDisappear {
            fallbackTask?.cancel()
            fallbackTask = nil
            accountChangeTask?.cancel()
            accountChangeTask = nil
            discovery.cancel()
        }
        .onChange(of: library.playRevision) { _, _ in refreshRecentlyPlayed() }
        .onChange(of: library.metadataRevision) { _, _ in refreshRecentlyPlayed() }
        .onChange(of: youTubeAccount.activeChannelID) { _, _ in
            discovery.accountScopeWillChange()
            accountChangeTask?.cancel()
            accountChangeTask = Task {
                await webHome.accountDidChange()
                guard !Task.isCancelled else { return }
                discovery.resumeAfterAccountScopeChange()
            }
        }
    }

}

struct YouTubeHomeMood: Identifiable {
    let id: String
    let en: String
    let zh: String
    let searchQuery: String

    var localizedTitle: String { tr(en, zh) }

    static let all: [YouTubeHomeMood] = [
        .init(id: "podcasts", en: "Podcasts", zh: "播客", searchQuery: "music podcasts"),
        .init(id: "energize", en: "Energize", zh: "活力", searchQuery: "energizing music"),
        .init(id: "feel-good", en: "Feel good", zh: "好心情", searchQuery: "feel good music"),
        .init(id: "workout", en: "Workout", zh: "健身", searchQuery: "workout music"),
        .init(id: "relax", en: "Relax", zh: "放松", searchQuery: "relaxing music"),
        .init(id: "party", en: "Party", zh: "派对", searchQuery: "party music"),
        .init(id: "commute", en: "Commute", zh: "通勤", searchQuery: "commute music"),
        .init(id: "focus", en: "Focus", zh: "专注", searchQuery: "focus music"),
        .init(id: "romance", en: "Romance", zh: "浪漫", searchQuery: "romantic music"),
        .init(id: "sad", en: "Sad", zh: "伤感", searchQuery: "sad songs"),
        .init(id: "sleep", en: "Sleep", zh: "睡眠", searchQuery: "sleep music")
    ]
}

struct HomeDiscoveryEmptyState: View {
    let onSearch: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Start your next listen", "开始下一次聆听"))
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            Text(tr("Search YouTube Music or retry discovery to fill this page.",
                    "搜索 YouTube Music，或重试发现内容来丰富此页面。"))
                .font(.subheadline)
                .foregroundStyle(BrandColors.textSecondary)
            HStack(spacing: 10) {
                Button(tr("Search", "搜索"), action: onSearch)
                Button(tr("Retry", "重试"), action: onRetry)
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.magenta)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner,
                                         style: .continuous))
    }
}

struct DiscoveryFailureStrip: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(BrandColors.textSecondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Button(tr("Retry", "重试"), action: onRetry)
                .buttonStyle(.bordered)
                .tint(BrandColors.magenta)
        }
        .padding(14)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner,
                                         style: .continuous))
    }
}

/// An explicit public-discovery fallback when the provider returned content
/// that could not be verified as music. This is intentionally distinct from
/// both a successful empty result and a transport failure.
struct DiscoveryUnavailableShelf: View {
    let title: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(BrandColors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                Text(tr(
                    "No reliable YouTube Music results are available right now.",
                    "暂时没有可靠的 YouTube Music 结果。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            Button(tr("Retry", "重试"), action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, AppleMusicTokens.contentPaddingX)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
