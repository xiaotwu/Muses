import Foundation
import SwiftData
import Observation

/// Complete local-only information needed to undo a playlist deletion during
/// the current session. It deliberately stores identifiers rather than model
/// objects so restoration can use a fresh SwiftData context.
struct PlaylistDeletionSnapshot: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let order: Int
        let trackID: UUID?
    }

    let name: String
    let createdAt: Date
    let pinned: Bool
    let items: [Item]
}

/// 歌单 CRUD + 排序服务。
///
/// 镜像 `YouTubeImportService` 模式:`@MainActor @Observable`,每次操作
/// 新建 `ModelContext`,mutation 后 `try? ctx.save()`。
@Observable
@MainActor
final class PlaylistService {
    private let modelContainer: ModelContainer
    private let log = AppLog.for("PlaylistService")
    private(set) var loadState: LoadState<[Playlist]> = .idle

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - 歌单 CRUD

    /// 创建歌单,返回新建 `Playlist`。
    @discardableResult
    func create(name: String) -> Playlist {
        let ctx = ModelContext(modelContainer)
        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        ctx.insert(playlist)
        try? ctx.save()
        log.info("创建歌单 \(playlist.name)")
        notifyPlaylistsChanged()
        return playlist
    }

    /// 重命名歌单。
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
        try? playlist.modelContext?.save()
        notifyPlaylistsChanged()
    }

    /// 删除歌单(级联删 items)。
    func delete(_ playlist: Playlist) {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id }
        )
        if let p = try? ctx.fetch(descriptor).first {
            ctx.delete(p)
            try? ctx.save()
            log.info("删除歌单 \(id)")
            notifyPlaylistsChanged()
        }
    }

    /// Deletes a local playlist and returns a one-session restore capsule.
    /// The playlist's tracks remain untouched; detached item rows are restored
    /// as such if their track was removed in the meantime.
    func deleteWithUndoSnapshot(_ playlist: Playlist) -> PlaylistDeletionSnapshot? {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        guard let stored = try? ctx.fetch(descriptor).first else { return nil }

        let snapshot = PlaylistDeletionSnapshot(
            name: stored.name,
            createdAt: stored.createdAt,
            pinned: stored.pinned,
            items: (stored.items ?? []).sorted { $0.order < $1.order }.map {
                .init(order: $0.order, trackID: $0.track?.id)
            }
        )
        ctx.delete(stored)
        do {
            try ctx.save()
            log.info("删除歌单 (id)，可在当前会话撤销")
            notifyPlaylistsChanged()
            return snapshot
        } catch {
            log.warning("删除歌单失败: (error.localizedDescription)")
            return nil
        }
    }

    /// Restores a deletion capsule once. Missing tracks remain represented by
    /// a detached playlist item, matching the model's existing nullify rule.
    @discardableResult
    func restore(_ snapshot: PlaylistDeletionSnapshot) -> Playlist? {
        let ctx = ModelContext(modelContainer)
        let restored = Playlist(name: snapshot.name, createdAt: snapshot.createdAt,
                                pinned: snapshot.pinned)
        ctx.insert(restored)
        var restoredItems: [PlaylistItem] = []
        for item in snapshot.items {
            let track: Track?
            if let id = item.trackID {
                track = try? ctx.fetch(FetchDescriptor<Track>(
                    predicate: #Predicate { $0.id == id }
                )).first
            } else {
                track = nil
            }
            let restoredItem = PlaylistItem(order: item.order, playlist: restored, track: track)
            ctx.insert(restoredItem)
            restoredItems.append(restoredItem)
        }
        restored.items = restoredItems
        do {
            try ctx.save()
            notifyPlaylistsChanged()
            return restored
        } catch {
            log.warning("恢复已删除歌单失败: (error.localizedDescription)")
            return nil
        }
    }

    private func notifyPlaylistsChanged() {
        NotificationCenter.default.post(name: .musesPlaylistsChanged, object: nil)
    }

    /// 查询所有歌单(按创建时间降序)。
    func fetchAll() -> [Playlist] {
        let previous = loadState.value
        loadState = .loading(previous: previous)
        let ctx = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        do {
            let values = try ctx.fetch(descriptor)
            loadState = values.isEmpty ? .empty : .content(values)
            return values
        } catch {
            loadState = .failure(message: error.localizedDescription,
                                 staleValue: previous)
            return previous ?? []
        }
    }

    // MARK: - 条目管理

    /// 向歌单追加一首 Track(order = max+1)。
    func addTrack(_ playlist: Playlist, track: Track) {
        let ctx = ModelContext(modelContainer)
        let playlistId = playlist.id
        let trackId = track.id

        // 在新 context 中获取 playlist + track 的持久化引用
        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistId }
        )).first else { return }
        guard let t = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId }
        )).first else { return }

        // 去重:同 track 已在歌单中则跳过
        let existingTrackIds = (p.items ?? []).compactMap { $0.track?.id }
        if existingTrackIds.contains(trackId) { return }

        let nextOrder = (p.items ?? []).map { $0.order }.max() ?? -1
        let item = PlaylistItem(order: nextOrder + 1, playlist: p, track: t)
        ctx.insert(item)
        if var items = p.items {
            items.append(item)
            p.items = items
        } else {
            p.items = [item]
        }
        try? ctx.save()
    }

    /// 从歌单移除条目(删除 item + 重排剩余 order)。
    func removeItem(_ item: PlaylistItem) {
        let ctx = ModelContext(modelContainer)
        let itemId = item.id
        guard let i = try? ctx.fetch(FetchDescriptor<PlaylistItem>(
            predicate: #Predicate { $0.id == itemId }
        )).first else { return }
        let playlist = i.playlist
        ctx.delete(i)
        try? ctx.save()

        // 重排剩余 order
        if let playlist, var items = playlist.items {
            items.sort { $0.order < $1.order }
            for (idx, item) in items.enumerated() {
                item.order = idx
            }
            playlist.items = items
            try? ctx.save()
        }
    }

    /// 拖拽重排:将 `from` 位置的条目移到 `to` 位置,重排 order。
    func moveItem(in playlist: Playlist, from: Int, to: Int) {
        guard var items = playlist.items?.sorted(by: { $0.order < $1.order }),
              from < items.count, to <= items.count else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(to, items.count))
        for (idx, item) in items.enumerated() {
            item.order = idx
        }
        playlist.items = items
        try? playlist.modelContext?.save()
    }

    // MARK: - 钉选

    /// 切换歌单钉选状态。
    func togglePin(_ playlist: Playlist) {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id }
        )).first else { return }
        p.pinned.toggle()
        try? ctx.save()
        notifyPlaylistsChanged()
    }

    /// 获取已钉选歌单(按名称排序)。
    func pinnedPlaylists() -> [Playlist] {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.pinned == true },
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? ctx.fetch(desc)) ?? []
    }

}
