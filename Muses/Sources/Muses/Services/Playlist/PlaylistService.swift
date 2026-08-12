import Foundation
import SwiftData
import Observation

/// 歌单 CRUD + 排序服务。
///
/// 镜像 `YouTubeImportService` 模式:`@MainActor @Observable`,每次操作
/// 新建 `ModelContext`,mutation 后 `try? ctx.save()`。
@Observable
@MainActor
final class PlaylistService {
    private let modelContainer: ModelContainer
    private let log = AppLog.for("PlaylistService")

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
        return playlist
    }

    /// 重命名歌单。
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
        try? playlist.modelContext?.save()
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
        }
    }

    /// 查询所有歌单(按创建时间降序)。
    func fetchAll() -> [Playlist] {
        let ctx = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return (try? ctx.fetch(descriptor)) ?? []
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
}