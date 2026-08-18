import Foundation
import Observation

/// 全局搜索服务:跨本地资料库(歌曲/专辑/艺术家)+ YouTube 并发搜索,带 debounce。
/// 本地结果即时返回,YouTube 结果异步填充。
@Observable
@MainActor
final class GlobalSearchService {
    var query: String = "" { didSet { scheduleSearch() } }

    private(set) var trackResults: [Track] = []
    private(set) var albumResults: [Album] = []
    private(set) var artistResults: [Artist] = []
    private(set) var noteResults: [NotesService.NoteSearchHit] = []
    private(set) var youtubeResults: [YTDlpBridge.YTDlpPlaylistEntry] = []
    private(set) var isSearchingYouTube = false

    private let library: LibraryService
    let youTubeSearch: YouTubeSearchService?
    private let notes: NotesService?
    private var searchTask: Task<Void, Never>?
    private let debounceMs: UInt64

    init(library: LibraryService,
         youTubeSearch: YouTubeSearchService? = nil,
         notes: NotesService? = nil,
         debounceMs: UInt64 = 250) {
        self.library = library
        self.youTubeSearch = youTubeSearch
        self.notes = notes
        self.debounceMs = debounceMs
    }

    /// 清除所有结果(关闭面板时调用)。
    func reset() {
        query = ""
        trackResults = []
        albumResults = []
        artistResults = []
        noteResults = []
        youtubeResults = []
        isSearchingYouTube = false
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - Debounced search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            trackResults = []
            albumResults = []
            artistResults = []
            noteResults = []
            youtubeResults = []
            isSearchingYouTube = false
            return
        }
        let ms = debounceMs
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(query: q)
        }
    }

    private func performSearch(query: String) async {
        // 本地搜索 — 即时
        let tracks = library.allTracks(search: query)
        let albums = library.allAlbums().filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.albumArtist.localizedCaseInsensitiveContains(query)
        }
        let artists = library.allArtists().filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        trackResults = tracks
        albumResults = albums
        artistResults = artists
        // 笔记搜索(Phase 21):ffNotes 关时 searchNotes 仍可读已存数据;为空则不显示该区段。
        if let notes {
            noteResults = notes.searchNotes(query: query)
        }

        // YouTube 搜索 — 异步
        guard let youTubeSearch else { return }
        isSearchingYouTube = true
        do {
            let yt = try await youTubeSearch.search(query: query)
            if !Task.isCancelled {
                youtubeResults = yt
            }
        } catch {
            // 静默 — YouTube 搜索失败不阻塞本地结果
        }
        isSearchingYouTube = false
    }
}