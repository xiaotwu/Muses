import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 21 — Notes & Bookmarks 验收(对应 Final Spec §10.7 Feature 7):
/// - `TrackNote` / `TrackBookmark` / `AlbumNote` @Model 持久化;
/// - `NotesService`:曲目笔记 upsert(空→删)/ 专辑笔记 upsert /
///   书签 CRUD(按 timestampMs 升序)/ `searchNotes` 返回含 owner 标题的命中;
/// - 功能开关 `ffNotes`:关闭时写入为 no-op,读取仍可用。
@MainActor
@Suite("Phase 21 Notes & Bookmarks")
struct Phase21NotesTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    /// 开启 ffNotes 的服务(生产默认读 UserDefaults 为 false,测试注入 true)。
    private func makeNotes(container: ModelContainer, enabled: Bool = true) -> NotesService {
        NotesService(modelContainer: container, enabledProvider: { enabled })
    }

    @discardableResult
    private func seedTrack(_ container: ModelContainer, title: String, artist: String = "Artist") -> Track {
        let ctx = ModelContext(container)
        let track = Track(source: .local, title: title, artist: artist, durationMs: 200000)
        ctx.insert(track)
        try? ctx.save()
        return track
    }

    @discardableResult
    private func seedAlbum(_ container: ModelContainer, title: String, artist: String = "Artist") -> Album {
        let ctx = ModelContext(container)
        let album = Album(title: title, albumArtist: artist)
        ctx.insert(album)
        try? ctx.save()
        return album
    }

    private func fetchAll<T: PersistentModel>(_ container: ModelContainer, _ type: T.Type) -> [T] {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<T>())) ?? []
    }

    // MARK: - 曲目笔记

    @Test("曲目笔记 upsert:写入 → 更新同行 → 空内容删除")
    func trackNoteUpsert() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let track = seedTrack(container, title: "Song A")

        notes.setTrackNote(trackId: track.id, content: "first thought")
        #expect(fetchAll(container, TrackNote.self).count == 1)
        #expect(notes.note(forTrack: track.id)?.content == "first thought")

        // 第二次写同 trackId → 更新同一行,不新增
        notes.setTrackNote(trackId: track.id, content: "second thought")
        #expect(fetchAll(container, TrackNote.self).count == 1)
        #expect(notes.note(forTrack: track.id)?.content == "second thought")

        // 空内容 → 删除该行
        notes.setTrackNote(trackId: track.id, content: "   ")
        #expect(fetchAll(container, TrackNote.self).isEmpty)
        #expect(notes.note(forTrack: track.id) == nil)
    }

    // MARK: - 专辑笔记

    @Test("专辑笔记 upsert:写入 → 更新 → 空删除")
    func albumNoteUpsert() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let album = seedAlbum(container, title: "Album A")

        notes.setAlbumNote(albumId: album.id, content: "review")
        #expect(fetchAll(container, AlbumNote.self).count == 1)
        #expect(notes.note(forAlbum: album.id)?.content == "review")

        notes.setAlbumNote(albumId: album.id, content: "updated review")
        #expect(fetchAll(container, AlbumNote.self).count == 1)
        #expect(notes.note(forAlbum: album.id)?.content == "updated review")

        notes.setAlbumNote(albumId: album.id, content: "")
        #expect(fetchAll(container, AlbumNote.self).isEmpty)
    }

    // MARK: - 书签 CRUD

    @Test("书签 CRUD + 按 timestampMs 升序读取")
    func bookmarkCrudAndOrder() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let track = seedTrack(container, title: "Song B")

        // 升序插入乱序:30s, 10s, 50s → 读取应为 10/30/50
        notes.addBookmark(trackId: track.id, timestampMs: 30, title: "bridge", note: nil)
        notes.addBookmark(trackId: track.id, timestampMs: 10, title: "verse", note: "start")
        notes.addBookmark(trackId: track.id, timestampMs: 50, title: "outro", note: nil)

        let bms = notes.bookmarks(forTrack: track.id)
        #expect(bms.count == 3)
        #expect(bms.map(\.timestampMs) == [10, 30, 50])

        // 删除中间一条
        notes.removeBookmark(id: bms[1].id)
        #expect(notes.bookmarks(forTrack: track.id).count == 2)

        // 更新标题/笔记
        let first = notes.bookmarks(forTrack: track.id)[0]
        notes.updateBookmark(id: first.id, title: "renamed", note: "detail")
        let after = notes.bookmarks(forTrack: track.id).first(where: { $0.id == first.id })!
        #expect(after.title == "renamed")
        #expect(after.note == "detail")
    }

    @Test("书签按 trackId 隔离:只返回该曲目的书签")
    func bookmarkIsolation() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let t1 = seedTrack(container, title: "T1")
        let t2 = seedTrack(container, title: "T2")

        notes.addBookmark(trackId: t1.id, timestampMs: 5, title: "a", note: nil)
        notes.addBookmark(trackId: t2.id, timestampMs: 8, title: "b", note: nil)
        notes.addBookmark(trackId: t2.id, timestampMs: 2, title: "c", note: nil)

        #expect(notes.bookmarks(forTrack: t1.id).count == 1)
        #expect(notes.bookmarks(forTrack: t2.id).map(\.timestampMs) == [2, 8])
    }

    // MARK: - 搜索

    @Test("searchNotes:跨曲目/专辑笔记内容匹配 + 返回 owner 标题")
    func searchNotesResolvesOwnerTitles() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let track = seedTrack(container, title: "Bohemian Rhapsody")
        let album = seedAlbum(container, title: "A Night at the Opera")

        notes.setTrackNote(trackId: track.id, content: "the operatic section is wild")
        notes.setAlbumNote(albumId: album.id, content: "Queen's best, operatic in scope")

        // 命中两个(都含 "operatic")
        let hits = notes.searchNotes(query: "operatic")
        #expect(hits.count == 2)
        let trackHit = hits.first { $0.kind == .trackNote }!
        #expect(trackHit.ownerTitle == "Bohemian Rhapsody")
        #expect(trackHit.snippet.contains("operatic"))
        let albumHit = hits.first { $0.kind == .albumNote }!
        #expect(albumHit.ownerTitle == "A Night at the Opera")

        // 大小写无关
        #expect(notes.searchNotes(query: "OPERATIC").count == 2)
        // 空查询返回空
        #expect(notes.searchNotes(query: "   ").isEmpty)
        // 无匹配
        #expect(notes.searchNotes(query: "nonexistent-term").isEmpty)
    }

    @Test("searchNotes:owner 不存在时回退到占位标题")
    func searchNotesFallbackTitle() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        // 直接写一条 trackId 指向不存在 Track 的笔记
        notes.setTrackNote(trackId: UUID(), content: "orphan note about solo")
        let hits = notes.searchNotes(query: "solo")
        #expect(hits.count == 1)
        // 回退占位(不崩、非空)
        #expect(!hits[0].ownerTitle.isEmpty)
    }

    // MARK: - 功能开关

    @Test("ffNotes 关闭时写入为 no-op,读取仍可返回已存数据")
    func flagDisablesWrites() throws {
        let container = try makeContainer()
        // 先用开启的服务写入一条笔记 + 一条书签
        let on = makeNotes(container: container, enabled: true)
        let track = seedTrack(container, title: "Song C")
        on.setTrackNote(trackId: track.id, content: "seeded")
        on.addBookmark(trackId: track.id, timestampMs: 12, title: nil, note: nil)
        #expect(on.note(forTrack: track.id)?.content == "seeded")
        #expect(on.bookmarks(forTrack: track.id).count == 1)

        // 切到关闭:写入/删除/更新均为 no-op
        let off = makeNotes(container: container, enabled: false)
        off.setTrackNote(trackId: track.id, content: "should not persist")
        off.setTrackNote(trackId: track.id, content: "")        // 空内容删除也应 no-op
        off.addBookmark(trackId: track.id, timestampMs: 99, title: nil, note: nil)
        off.removeBookmark(id: on.bookmarks(forTrack: track.id)[0].id)
        off.updateBookmark(id: on.bookmarks(forTrack: track.id)[0].id, title: "x", note: "y")
        off.setAlbumNote(albumId: UUID(), content: "ignored")

        // 已存数据未被动
        #expect(on.note(forTrack: track.id)?.content == "seeded")
        #expect(on.bookmarks(forTrack: track.id).count == 1)

        // 关闭服务的 isEnabled == false
        #expect(off.isEnabled == false)
        #expect(on.isEnabled == true)
    }

    // MARK: - 持久化往返

    @Test("三种模型跨独立 context 持久化往返")
    func modelsPersistAcrossContexts() throws {
        let container = try makeContainer()
        let notes = makeNotes(container: container)
        let track = seedTrack(container, title: "Persisted Song")
        let album = seedAlbum(container, title: "Persisted Album")

        notes.setTrackNote(trackId: track.id, content: "note body")
        notes.addBookmark(trackId: track.id, timestampMs: 42.5, title: "mid", note: "desc")
        notes.setAlbumNote(albumId: album.id, content: "album body")

        // 用一个全新 context 读取(模拟下次启动)
        let ctx = ModelContext(container)
        let tns = (try? ctx.fetch(FetchDescriptor<TrackNote>())) ?? []
        let bms = (try? ctx.fetch(FetchDescriptor<TrackBookmark>())) ?? []
        let ans = (try? ctx.fetch(FetchDescriptor<AlbumNote>())) ?? []
        #expect(tns.count == 1 && tns[0].content == "note body")
        #expect(bms.count == 1 && bms[0].timestampMs == 42.5 && bms[0].title == "mid")
        #expect(ans.count == 1 && ans[0].content == "album body")
    }
}