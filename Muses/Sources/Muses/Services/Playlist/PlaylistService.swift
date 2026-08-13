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

    // MARK: - M3U 导入/导出

    /// 从 M3U/M3U8 文件导入曲目到歌单。
    /// 按 filePath 匹配已有 Track,未匹配的跳过(不自动扫描新文件)。
    /// 返回成功匹配并添加的曲目数。
    @discardableResult
    func importM3U(_ playlist: Playlist, from url: URL) -> Int {
        guard let paths = try? M3UService.parse(url: url) else { return 0 }
        let ctx = ModelContext(modelContainer)
        let playlistId = playlist.id

        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistId }
        )).first else { return 0 }

        // 预加载所有本地 Track,按 filePath 和文件名建立索引(M3U 导入是手动操作,全量 fetch 可接受)
        let allTracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        let byPath: [String: Track] = Dictionary(uniqueKeysWithValues: allTracks.compactMap { t in
            t.filePath.map { ($0, t) }
        })
        let byFilename: [String: Track] = Dictionary(allTracks.compactMap { t in
            t.filePath.map { (( $0 as NSString).lastPathComponent, t) }
        }, uniquingKeysWith: { first, _ in first })

        let existingTrackIds = Set((p.items ?? []).compactMap { $0.track?.id })
        var added = 0
        var nextOrder = (p.items ?? []).map { $0.order }.max() ?? -1

        for path in paths {
            // 先按绝对路径匹配,再按文件名兜底
            let track = byPath[path] ?? {
                let fname = (path as NSString).lastPathComponent
                return byFilename[fname]
            }()
            guard let track else { continue }
            if existingTrackIds.contains(track.id) { continue }
            nextOrder += 1
            let item = PlaylistItem(order: nextOrder, playlist: p, track: track)
            ctx.insert(item)
            if var items = p.items { items.append(item); p.items = items }
            else { p.items = [item] }
            added += 1
        }

        try? ctx.save()
        log.info("M3U 导入:从 \(url.lastPathComponent) 添加 \(added) 首到歌单 \(playlist.name)")
        return added
    }

    /// 导出歌单为 M3U 文件。
    /// `relativeTo` 非 nil 时,filePath 转为相对路径。
    func exportM3U(_ playlist: Playlist, to url: URL, relativeTo: URL? = nil) {
        let ctx = ModelContext(modelContainer)
        let playlistId = playlist.id
        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistId }
        )).first else { return }

        let items = (p.items ?? []).sorted { $0.order < $1.order }
        let entries: [(filePath: String, title: String, durationSeconds: Double)] = items.compactMap { item in
            guard let track = item.track, let fp = track.filePath else { return nil }
            let title = "\(track.artist) - \(track.title)"
            return (filePath: fp, title: title, durationSeconds: track.durationSeconds)
        }

        let content = M3UService.export(entries: entries, relativeTo: relativeTo)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        log.info("M3U 导出:\(entries.count) 首到 \(url.path)")
    }
}