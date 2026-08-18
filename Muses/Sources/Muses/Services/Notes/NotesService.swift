import Foundation
import Observation
import SwiftData

/// 笔记 & 书签服务(Final Spec §10.7 Feature 7 — Notes & Bookmarks)。
///
/// 持有 `TrackNote` / `TrackBookmark` / `AlbumNote` 三表的读写入口。
/// - 曲目笔记 / 专辑笔记:按 ownerId upsert(每 owner 一条);空内容时删除行。
/// - 曲目书签:CRUD,按 `timestampMs` 升序读取。
/// - `searchNotes(query:)`:跨 TrackNote/AlbumNote 内容做大小写无关包含匹配,
///   反规范化返回 `NoteSearchHit`(含 owner 标题),供 `GlobalSearchService` 渲染。
///
/// 功能开关 `PrefKey.ffNotes`(默认关):关闭时写入方法为 no-op,读取仍可用(供已存数据展示);
/// 与同代服务「关 = no-op」约定一致。`isEnabled` 实时读开关源。
@Observable
@MainActor
final class NotesService {
    private let modelContainer: ModelContainer
    private let enabledProvider: () -> Bool
    private(set) var revision: Int = 0
    var isEnabled: Bool { enabledProvider() }
    var container: ModelContainer { modelContainer }

    init(modelContainer: ModelContainer,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffNotes)
    }) {
        self.modelContainer = modelContainer
        self.enabledProvider = enabledProvider
    }

    // MARK: - 曲目笔记

    func note(forTrack trackId: UUID) -> TrackNote? {
        let ctx = modelContainer.mainContext
        return (try? ctx.fetch(FetchDescriptor<TrackNote>()))?
            .first(where: { $0.trackId == trackId })
    }

    /// 写入曲目笔记(upsert)。空内容 → 删除该行。功能关闭时 no-op。
    func setTrackNote(trackId: UUID, content: String) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        let existing = (try? ctx.fetch(FetchDescriptor<TrackNote>()))?
            .first(where: { $0.trackId == trackId })
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing { ctx.delete(existing); try? ctx.save(); revision &+= 1 }
            return
        }
        if let existing {
            existing.content = content; existing.updatedAt = .init()
        } else {
            ctx.insert(TrackNote(trackId: trackId, content: content))
        }
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - 曲目书签

    func bookmarks(forTrack trackId: UUID) -> [TrackBookmark] {
        let ctx = modelContainer.mainContext
        return ((try? ctx.fetch(FetchDescriptor<TrackBookmark>())) ?? [])
            .filter { $0.trackId == trackId }
            .sorted { $0.timestampMs < $1.timestampMs }
    }

    @discardableResult
    func addBookmark(trackId: UUID, timestampMs: Double, title: String?, note: String?) -> UUID? {
        guard isEnabled else { return nil }
        let ctx = modelContainer.mainContext
        let bm = TrackBookmark(trackId: trackId, timestampMs: timestampMs, title: title, note: note)
        ctx.insert(bm)
        try? ctx.save()
        revision &+= 1
        return bm.id
    }

    func removeBookmark(id: UUID) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        guard let bm = (try? ctx.fetch(FetchDescriptor<TrackBookmark>()))?
            .first(where: { $0.id == id }) else { return }
        ctx.delete(bm)
        try? ctx.save()
        revision &+= 1
    }

    func updateBookmark(id: UUID, title: String?, note: String?) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        guard let bm = (try? ctx.fetch(FetchDescriptor<TrackBookmark>()))?
            .first(where: { $0.id == id }) else { return }
        bm.title = title; bm.note = note
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - 专辑笔记

    func note(forAlbum albumId: UUID) -> AlbumNote? {
        let ctx = modelContainer.mainContext
        return (try? ctx.fetch(FetchDescriptor<AlbumNote>()))?
            .first(where: { $0.albumId == albumId })
    }

    /// 写入专辑笔记(upsert)。空内容 → 删除。功能关闭时 no-op。
    func setAlbumNote(albumId: UUID, content: String) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        let existing = (try? ctx.fetch(FetchDescriptor<AlbumNote>()))?
            .first(where: { $0.albumId == albumId })
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing { ctx.delete(existing); try? ctx.save(); revision &+= 1 }
            return
        }
        if let existing {
            existing.content = content; existing.updatedAt = .init()
        } else {
            ctx.insert(AlbumNote(albumId: albumId, content: content))
        }
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - 搜索

    /// 笔记搜索结果(反规范化:含 owner 标题供 UI 展示)。
    struct NoteSearchHit: Identifiable, Sendable {
        let id: UUID
        let kind: Kind
        let ownerId: UUID
        let ownerTitle: String
        let snippet: String
        enum Kind: Sendable { case trackNote, albumNote }
    }

    /// 跨 TrackNote/AlbumNote 内容做包含匹配;`query` 为空返回空。解析 owner 标题(Track/Album 不存在则兜底)。
    func searchNotes(query: String) -> [NoteSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let needle = q.lowercased()
        let ctx = modelContainer.mainContext
        var hits: [NoteSearchHit] = []
        if let trackNotes = try? ctx.fetch(FetchDescriptor<TrackNote>()) {
            let tracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
            for n in trackNotes where n.content.lowercased().contains(needle) {
                let title = tracks.first(where: { $0.id == n.trackId })?.title ?? tr("Unknown track", "未知曲目")
                hits.append(.init(id: n.id, kind: .trackNote, ownerId: n.trackId,
                                  ownerTitle: title, snippet: snippet(of: n.content, needle: needle)))
            }
        }
        if let albumNotes = try? ctx.fetch(FetchDescriptor<AlbumNote>()) {
            let albums = (try? ctx.fetch(FetchDescriptor<Album>())) ?? []
            for n in albumNotes where n.content.lowercased().contains(needle) {
                let title = albums.first(where: { $0.id == n.albumId })?.title ?? tr("Unknown album", "未知专辑")
                hits.append(.init(id: n.id, kind: .albumNote, ownerId: n.albumId,
                                  ownerTitle: title, snippet: snippet(of: n.content, needle: needle)))
            }
        }
        return hits
    }

    /// 取匹配处附近最多 80 字的片段(供搜索结果预览)。
    private func snippet(of content: String, needle: String) -> String {
        let lower = content.lowercased()
        guard let range = lower.range(of: needle) else { return String(content.prefix(80)) }
        let idx = range.lowerBound
        let start = content.index(idx, offsetBy: -min(40, content.distance(from: content.startIndex, to: idx)), limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(idx, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end])
    }
}