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
    var query: String = "" { didSet { scheduleSearch() } }
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
         debounceMs: UInt64 = 250) {
        self.library = library
        self.catalog = catalog
        self.youTubeSearch = youTubeSearch
        self.notes = notes
        self.debounceMs = debounceMs
    }

    var hasResults: Bool {
        !trackResults.isEmpty
            || !releaseResults.isEmpty
            || !catalogArtistResults.isEmpty
            || !noteResults.isEmpty
            || !youtubeResults.isEmpty
    }

    func reset() {
        searchTask?.cancel()
        searchTask = nil
        query = ""
        scope = .all
        clearAllResults()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAllResults()
            return
        }
        let milliseconds = debounceMs
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: trimmed)
        }
    }

    func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAllResults()
            return
        }

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

        guard requestedScope.searchesYouTube, let youTubeSearch else {
            youtubeResults = []
            isSearchingYouTube = false
            return
        }

        isSearchingYouTube = true
        defer { isSearchingYouTube = false }
        do {
            let results = try await youTubeSearch.search(query: trimmed)
            guard !Task.isCancelled, scope == requestedScope else { return }
            youtubeResults = results
        } catch {
            guard !Task.isCancelled, scope == requestedScope else { return }
            youtubeResults = []
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
        clearLibraryResults()
        youtubeResults = []
        isSearchingYouTube = false
    }
}
