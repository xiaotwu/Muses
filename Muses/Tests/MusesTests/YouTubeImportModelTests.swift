import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("YouTubeImportModel")
struct YouTubeImportModelTests {

    /// 创建 YouTubeImport + items + 关联 .youtube Track,验证关系建立。
    @Test("创建 import + items + 关联 .youtube Track")
    func createImportWithItems() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext

        let imp = YouTubeImport(playlistId: "PLtest1", url: "https://youtube.com/playlist?list=PLtest1",
                                title: "My Playlist", channel: "Chan")
        ctx.insert(imp)

        let item1 = YouTubeImportItem(youTubeId: "vid1", title: "Song A",
                                       artist: "Chan", durationMs: 201000, order: 0)
        let item2 = YouTubeImportItem(youTubeId: "vid2", title: "Song B",
                                       artist: "Chan", durationMs: 180000, order: 1)
        ctx.insert(item1); ctx.insert(item2)

        // 懒创建 .youtube Track
        let t1 = Track(source: .youtube, title: "Song A", artist: "Chan",
                       durationMs: 201000, youTubeId: "vid1")
        ctx.insert(t1)
        item1.track = t1

        imp.items = [item1, item2]
        try ctx.save()

        // 验证(按 order 排序,SwiftData 关系数组不保证插入顺序)
        let fetched = try ctx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(fetched.count == 1)
        let sortedItems = (fetched[0].items ?? []).sorted { $0.order < $1.order }
        #expect(sortedItems.count == 2)
        #expect(sortedItems[0].track?.source == .youtube)
        #expect(sortedItems[0].track?.youTubeId == "vid1")
        #expect(sortedItems[0].youTubeId == "vid1")
        #expect(sortedItems[1].youTubeId == "vid2")
    }

    /// 删除 import 级联删 items,但保留懒创建的 .youtube Track。
    @Test("删除 import 级联 items 但保留 Track")
    func deleteImportCascadesItemsKeepsTrack() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext

        let imp = YouTubeImport(playlistId: "PLdel", url: "https://youtube.com/playlist?list=PLdel",
                                title: "Del", channel: "C")
        ctx.insert(imp)
        let item = YouTubeImportItem(youTubeId: "v1", title: "S", artist: "C", order: 0)
        ctx.insert(item)
        let t = Track(source: .youtube, title: "S", artist: "C", youTubeId: "v1")
        ctx.insert(t)
        item.track = t
        imp.items = [item]
        try ctx.save()

        // 删 import
        ctx.delete(imp)
        try ctx.save()

        // items 级联删除
        let itemsLeft = try ctx.fetch(FetchDescriptor<YouTubeImportItem>())
        #expect(itemsLeft.isEmpty)

        // Track 保留(nullify)
        let tracksLeft = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracksLeft.count == 1)
        #expect(tracksLeft[0].youTubeId == "v1")
        // 反向关联被 nullify
        #expect(tracksLeft[0].youTubeImportItem == nil)
    }

    /// localAdditions 添加/移除,验证本地附加关系。
    @Test("localAdditions 添加和移除")
    func localAdditionsAddRemove() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext

        let imp = YouTubeImport(playlistId: "PLla", url: "https://youtube.com/playlist?list=PLla",
                                title: "LA", channel: "C")
        ctx.insert(imp)

        let localT = Track(source: .local, title: "Local Song", artist: "Me",
                           filePath: "/tmp/song.flac")
        ctx.insert(localT)
        imp.localAdditions = [localT]
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<YouTubeImport>()).first!
        #expect(fetched.localAdditions?.count == 1)
        #expect(fetched.localAdditions?[0].title == "Local Song")
        // 反向关联
        #expect(localT.youTubeImportLocalAddition?.playlistId == "PLla")

        // 移除
        fetched.localAdditions = []
        try ctx.save()
        let fetched2 = try ctx.fetch(FetchDescriptor<YouTubeImport>()).first!
        #expect(fetched2.localAdditions?.count == 0)
        // Track 保留(nullify)
        let tracks = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracks.count == 1)
        #expect(tracks[0].youTubeImportLocalAddition == nil)
    }
}