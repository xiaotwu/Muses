import Foundation
import Observation

enum GlobalSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case library
    case youtube

    var id: Self { self }
    var searchesLibrary: Bool { self != .youtube }
    var searchesYouTube: Bool { self != .library }
}

/// Search facade for the versioned YouTube-native library and rebuildable catalog.
/// SwiftData models are projected to immutable values before reaching the UI.
@Observable
@MainActor
final class GlobalSearchService {
    let musicCatalog = MusicCatalogBrowser()

    var query: String = "" { didSet { if oldValue != query { scheduleSearch() } } }
    var scope: GlobalSearchScope = .all {
        didSet {
            guard oldValue != scope else { return }
            clearResultsExcluded(by: scope)
            scheduleSearch()
        }
    }

    private(set) var trackResults: [TrackSnapshot] = []
    private(set) var releaseResults: [CatalogReleaseProjection] = []
    private(set) var catalogArtistResults: [CatalogArtistProjection] = []
    private(set) var noteResults: [NotesService.NoteSearchHit] = []
    private(set) var youtubeResults: [YTDlpBridge.YTDlpPlaylistEntry] = []
    private(set) var isSearchingYouTube = false
    private(set) var wasCancelled = false
    private let remoteSearch: (@MainActor (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])?

    private(set) var canLoadMore = false
    private var loadedLimit = 0
    private var activeQuery = ""
    private var retryingMore = false
    private var requestID = UUID()
    private(set) var youtubeError: String?

    private let library: LibraryService
    private let catalog: YouTubeCatalogService?
    let youTubeSearch: YouTubeSearchService?
    private let notes: NotesService?
    private var searchTask: Task<Void, Never>?
    private let debounceMs: UInt64

    init(library: LibraryService,
         catalog: YouTubeCatalogService? = nil,
         youTubeSearch: YouTubeSearchService? = nil,
         notes: NotesService? = nil,
         debounceMs: UInt64 = 250,
         remoteSearch: (@MainActor (String, Int) async throws -> [YTDlpBridge.YTDlpPlaylistEntry])? = nil) {
        self.library = library
        self.catalog = catalog
        self.youTubeSearch = youTubeSearch
        self.notes = notes
        self.debounceMs = debounceMs
        if let remoteSearch {
            self.remoteSearch = remoteSearch
        } else if let youTubeSearch {
            self.remoteSearch = { query, limit in try await youTubeSearch.search(query: query, limit: limit) }
        } else {
            self.remoteSearch = nil
        }
    }

    var hasResults: Bool {
        !trackResults.isEmpty
            || !releaseResults.isEmpty
            || !catalogArtistResults.isEmpty
            || !noteResults.isEmpty
            || !youtubeResults.isEmpty
    }

    func reset() {
        musicCatalog.clear()
        searchTask?.cancel()
        searchTask = nil
        query = ""
        scope = .all
        clearAllResults()
    }

    func cancelSearch() {
        musicCatalog.cancel()
        searchTask?.cancel()
        searchTask = nil
        requestID = UUID()
        isSearchingYouTube = false
        wasCancelled = true
    }

    func retrySearch() {
        if retryingMore { loadMore() } else { scheduleSearch() }
    }

    /// yt-dlp exposes a ranked prefix rather than a continuation token. Extend
    /// that prefix while preserving the already displayed order and identities.
    func loadMore() {
        guard canLoadMore, !isSearchingYouTube, !activeQuery.isEmpty else { return }
        searchTask?.cancel()
        isSearchingYouTube = true
        let text = activeQuery
        let limit = loadedLimit + 20
        searchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: text, limit: limit, extending: true)
        }
    }

    private func scheduleSearch() {
        musicCatalog.clear()
        searchTask?.cancel()
        clearAllResults()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAllResults()
            return
        }
        isSearchingYouTube = scope.searchesYouTube
        let milliseconds = debounceMs
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: trimmed)
        }
    }

    func performSearch(query: String, limit: Int = 20, extending: Bool = false) async {
        guard !Task.isCancelled else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAllResults()
            return
        }

        let expectedRequest = UUID()
        requestID = expectedRequest
        youtubeError = nil
        wasCancelled = false
        if !extending { youtubeResults = []; loadedLimit = 0; canLoadMore = false }
        activeQuery = trimmed
        retryingMore = extending
        let requestedScope = scope
        if requestedScope.searchesLibrary {
            let playable = library.allTracks(search: trimmed).filter {
                !$0.youTubeId.isEmpty
            }
            // Every playable YouTube row belongs to the single Songs result group,
            // including Tracks marked as music videos.
            trackResults = playable.map(TrackSnapshot.init(from:))

            let releases = catalog?.releases() ?? []
            releaseResults = releases.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.artistName.localizedCaseInsensitiveContains(trimmed)
            }
            catalogArtistResults = (catalog?.artists() ?? []).filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }

            if let notes {
                noteResults = notes.searchNotes(query: trimmed).filter { hit in
                    guard case .trackNote = hit.kind,
                          let track = library.track(by: hit.ownerId) else { return false }
                    return !track.youTubeId.isEmpty
                }
            } else {
                noteResults = []
            }
        } else {
            clearLibraryResults()
        }

        guard requestedScope.searchesYouTube else {
            youtubeResults = []
            isSearchingYouTube = false
            return
        }

        guard let remoteSearch else {
            isSearchingYouTube = false
            youtubeError = tr("YouTube search is unavailable.", "YouTube 搜索暂不可用。", zhHant: "YouTube 搜尋暫不可用。")
            return
        }
        isSearchingYouTube = true
        defer { if requestID == expectedRequest { isSearchingYouTube = false } }
        do {
            let results = try await remoteSearch(trimmed, limit)
            guard !Task.isCancelled, requestID == expectedRequest, scope == requestedScope else { return }
            var seen = Set(youtubeResults.map(\.id))
            let newResults = results.filter { $0.resourceKind != .unknown && seen.insert($0.id).inserted }
            youtubeResults += newResults
            loadedLimit = limit
            canLoadMore = results.count >= limit && (!extending || !newResults.isEmpty)
            retryingMore = false
        } catch {
            guard !Task.isCancelled, requestID == expectedRequest, scope == requestedScope else { return }
            if !extending { youtubeResults = [] }
            youtubeError = tr("YouTube search failed. Please try again.", "YouTube 搜索失败，请重试。", zhHant: "YouTube 搜尋失敗，請再試一次。")
        }
    }

    private func clearResultsExcluded(by scope: GlobalSearchScope) {
        if !scope.searchesLibrary { clearLibraryResults() }
        if !scope.searchesYouTube {
            youtubeResults = []
            isSearchingYouTube = false
        }
    }

    private func clearLibraryResults() {
        trackResults = []
        releaseResults = []
        catalogArtistResults = []
        noteResults = []
    }

    private func clearAllResults() {
        requestID = UUID()
        youtubeError = nil
        wasCancelled = false
        canLoadMore = false
        loadedLimit = 0
        activeQuery = ""
        retryingMore = false
        clearLibraryResults()
        youtubeResults = []
        isSearchingYouTube = false
    }
}
