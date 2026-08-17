import Testing
import Foundation
import SwiftData
@testable import Muses

/// 播放历史记录:`recordPlay` 写入 `lastPlayedAt`/`playCount` 并 bump `playRevision`;
/// `recentlyPlayedTracks` / `topArtistName` 据此返回结果。
@MainActor
@Suite("PlaybackHistory")
struct PlaybackHistoryTests {

    @Test("recordPlay 更新 lastPlayedAt / playCount / playRevision")
    func recordPlayUpdatesHistory() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let track = Track(source: .local, title: "T", artist: "A", durationMs: 1000,
                          filePath: "/tmp/x.wav")
        ctx.insert(track)
        try ctx.save()
        let trackId = track.id
        #expect(track.lastPlayedAt == nil)
        #expect(track.playCount == 0)

        let library = LibraryService(modelContainer: container,
                                     metadata: MetadataService(artworkCache: .default))
        let rev0 = library.playRevision
        library.recordPlay(trackId: trackId)
        // recordPlay 在独立 ModelContext 写入并 save;主 context 不会自动刷新,
        // 故用 fresh context 重新查询以看到最新值(生产 UI 走 fresh-context 查询同理)。
        func refetch() -> Track {
            let c = ModelContext(container)
            let d = FetchDescriptor<Track>(predicate: #Predicate { $0.id == trackId })
            return try! c.fetch(d).first!
        }
        let rev1 = library.playRevision
        #expect(rev1 == rev0 + 1)
        let after1 = refetch()
        #expect(after1.playCount == 1)
        #expect(after1.lastPlayedAt != nil)

        // 再次记录:playCount 累加,playRevision 再 bump
        library.recordPlay(trackId: trackId)
        #expect(library.playRevision == rev0 + 2)
        #expect(refetch().playCount == 2)
    }

    @Test("recentlyPlayedTracks 按 lastPlayedAt 倒序且包含本地+YouTube")
    func recentlyPlayedOrdering() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let a = Track(source: .local, title: "A", artist: "X", durationMs: 1000, filePath: "/tmp/a.wav")
        let b = Track(source: .youtube, title: "B", artist: "Y", durationMs: 2000, youTubeId: "ytB")
        let c = Track(source: .local, title: "C", artist: "Z", durationMs: 3000, filePath: "/tmp/c.wav")
        ctx.insert(a); ctx.insert(b); ctx.insert(c)
        // 模拟播放顺序:C 最早、A 中、B 最近
        a.lastPlayedAt = Date().addingTimeInterval(-200)
        b.lastPlayedAt = Date()
        c.lastPlayedAt = Date().addingTimeInterval(-400)
        try ctx.save()

        let library = LibraryService(modelContainer: container,
                                     metadata: MetadataService(artworkCache: .default))
        let recent = library.recentlyPlayedTracks(limit: 10)
        #expect(recent.count == 3)
        // 倒序:最近播放在前 → B、A、C
        #expect(recent[0].youTubeId == "ytB")
        #expect(recent[1].filePath == "/tmp/a.wav")
        #expect(recent[2].title == "C")
    }

    @Test("topArtistName 返回播放量最高的艺术家;无记录返回 nil")
    func topArtistByPlayCount() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let library = LibraryService(modelContainer: container,
                                     metadata: MetadataService(artworkCache: .default))
        // 无播放记录
        #expect(library.topArtistName() == nil)

        let t1 = Track(source: .local, title: "t1", artist: "Pop", albumArtist: "Pop",
                       durationMs: 1000, filePath: "/tmp/t1.wav")
        let t2 = Track(source: .local, title: "t2", artist: "Rock", albumArtist: "Rock",
                       durationMs: 1000, filePath: "/tmp/t2.wav")
        ctx.insert(t1); ctx.insert(t2)
        // Pop 播 5 次,Rock 播 2 次
        t1.playCount = 5
        t2.playCount = 2
        try ctx.save()

        #expect(library.topArtistName() == "Pop")
    }
}