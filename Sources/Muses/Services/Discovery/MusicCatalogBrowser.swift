import Foundation
import Observation

/// Shared search presentation state. A failed next page preserves existing rows
/// and its cursor; query/category changes invalidate every outstanding response.
@Observable @MainActor
final class MusicCatalogBrowser {
    private(set) var items: [MusicCatalogItem] = []
    private(set) var relatedItems: [MusicCatalogItem] = []
    private(set) var kind: MusicCatalogKind?
    private(set) var detail: MusicCatalogItem?
    private(set) var loading = false
    private(set) var failed = false
    private(set) var isStale = false
    private(set) var fetchedAt: Date?
    private(set) var region = "US"
    private(set) var nextCursor: MusicCatalogCursor?
    private var detailHistory: [MusicCatalogItem?] = [nil]
    private var historyIndex = 0
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < detailHistory.count }
    private var query = ""
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var retryingMore = false
    private let provider: any MusicCatalogProviding

    init(provider: any MusicCatalogProviding = CachedMusicCatalogProvider()) { self.provider = provider }

    func search(_ value: String, kind: MusicCatalogKind? = nil) {
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        detail = nil
        detailHistory = [nil]; historyIndex = 0
        start(extending: false)
    }

    func open(_ item: MusicCatalogItem) {
        guard item.id.hasPrefix("browse:") else { return }
        guard detail?.id != item.id else { return }
        detailHistory.removeSubrange((historyIndex + 1)..<detailHistory.count)
        detailHistory.append(item)
        if detailHistory.count > 100 { detailHistory.removeFirst() }
        historyIndex = detailHistory.count - 1
        detail = item
        start(extending: false)
    }

    func back() {
        guard canGoBack else { return }
        historyIndex -= 1; detail = detailHistory[historyIndex]; start(extending: false)
    }
    func forward() {
        guard canGoForward else { return }
        historyIndex += 1; detail = detailHistory[historyIndex]; start(extending: false)
    }
    func more() { guard nextCursor != nil, !loading else { return }; start(extending: true) }
    func retry() { start(extending: retryingMore) }
    func cancel() { task?.cancel(); task = nil; requestID = UUID(); loading = false }

    func clear() {
        cancel()
        detailHistory = [nil]; historyIndex = 0
        items = []; relatedItems = []; nextCursor = nil; detail = nil; kind = nil
        fetchedAt = nil; query = ""; failed = false; isStale = false
    }

    private func start(extending: Bool) {
        cancel()
        if !extending { items = []; relatedItems = []; nextCursor = nil; fetchedAt = nil; isStale = false }
        failed = false
        guard !query.isEmpty else { return }
        retryingMore = extending
        loading = true
        let expected = requestID
        let query = query, category = kind, destination = detail
        let cursor = extending ? nextCursor : nil
        task = Task { [weak self, provider] in
            do {
                let page: MusicCatalogPage
                if let cursor { page = try await provider.next(cursor) }
                else if let destination { page = try await provider.browse(destination.id) }
                else { page = try await provider.search(query, kind: category) }
                guard let self, !Task.isCancelled, self.requestID == expected else { return }
                if extending && destination == nil {
                    var seen = Set(self.items.map(\.id))
                    self.items += page.items.filter { seen.insert($0.id).inserted }
                } else { self.items += page.items }
                var seenRelated = Set(self.relatedItems.map(\.id))
                self.relatedItems += page.relatedItems.filter { seenRelated.insert($0.id).inserted }
                self.nextCursor = page.next
                self.isStale = page.isStale
                self.failed = page.refreshFailed
                self.fetchedAt = page.fetchedAt
                self.region = page.region
                self.loading = false
                self.retryingMore = false
            } catch {
                guard let self, !Task.isCancelled, self.requestID == expected else { return }
                self.loading = false
                self.failed = true
            }
        }
    }
}

extension MusicCatalogItem {
    var playableEntry: YTDlpBridge.YTDlpPlaylistEntry? {
        // Podcast playback requires the episode end/continuation policy; until
        // that integration lands, episodes remain browsable official links.
        guard [.song, .video].contains(kind), id.hasPrefix("video:") else { return nil }
        return .init(id: String(id.dropFirst(6)), title: title,
                     uploader: artists.isEmpty ? nil : artists.map(\.title).joined(separator: ", "),
                     track: kind == .song ? title : nil, album: releases.first?.title)
    }
}
