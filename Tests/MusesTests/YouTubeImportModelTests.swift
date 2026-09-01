import Testing
import Foundation
import SwiftData
@testable import Muses

@MainActor
@Suite("YouTubeImportModel")
struct YouTubeImportModelTests {

    /// Creates a YouTubeImport + items + linked .youtube Tracks, verifying the relationships.
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

        // Lazily create the .youtube Track
        let t1 = Track(title: "Song A", artist: "Chan",
                       durationMs: 201000, youTubeId: "vid1")
        ctx.insert(t1)
        item1.track = t1

        imp.items = [item1, item2]
        try ctx.save()

        // Verify (sorted by order; SwiftData relationship arrays do not guarantee insertion order)
        let fetched = try ctx.fetch(FetchDescriptor<YouTubeImport>())
        #expect(fetched.count == 1)
        let sortedItems = (fetched[0].items ?? []).sorted { $0.order < $1.order }
        #expect(sortedItems.count == 2)
        #expect(sortedItems[0].track?.youTubeId == "vid1")
        #expect(sortedItems[0].youTubeId == "vid1")
        #expect(sortedItems[1].youTubeId == "vid2")
    }

    /// Deleting an import cascades to items but keeps the lazily created .youtube Tracks.
    @Test("删除 import 级联 items 但保留 Track")
    func deleteImportCascadesItemsKeepsTrack() throws {
        let c = try makeModelContainer(inMemory: true)
        let ctx = c.mainContext

        let imp = YouTubeImport(playlistId: "PLdel", url: "https://youtube.com/playlist?list=PLdel",
                                title: "Del", channel: "C")
        ctx.insert(imp)
        let item = YouTubeImportItem(youTubeId: "v1", title: "S", artist: "C", order: 0)
        ctx.insert(item)
        let t = Track(title: "S", artist: "C", youTubeId: "v1")
        ctx.insert(t)
        item.track = t
        imp.items = [item]
        try ctx.save()

        // Delete the import
        ctx.delete(imp)
        try ctx.save()

        // items cascade-deleted
        let itemsLeft = try ctx.fetch(FetchDescriptor<YouTubeImportItem>())
        #expect(itemsLeft.isEmpty)

        // Tracks survive (nullify)
        let tracksLeft = try ctx.fetch(FetchDescriptor<Track>())
        #expect(tracksLeft.count == 1)
        #expect(tracksLeft[0].youTubeId == "v1")
        // The inverse relationship is nullified
        #expect((tracksLeft[0].youTubeImportItems ?? []).isEmpty)
    }

}
