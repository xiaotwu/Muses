import Foundation
import SwiftData
import Testing
@testable import Muses

@Suite("Library membership", .serialized)
@MainActor
struct LibraryMembershipTests {
    @Test("Playback resolution preserves identity without library membership; explicit import promotes it")
    func resolveThenImport() async throws {
        let container = try makeModelContainer(inMemory: true)
        let library = LibraryService(modelContainer: container)
        let search = YouTubeSearchService(bridge: MockImportBridge(), modelContainer: container)
        let entry = YTDlpBridge.YTDlpPlaylistEntry(id: "lY5V4hSLWY8", title: "Song", uploader: "Channel")
        let playable = try await search.resolveTrack(entry: entry)
        #expect(library.allTracks().isEmpty)
        #expect(library.allTracks(search: "Song").isEmpty)
        library.recordPlay(trackId: playable.id)
        #expect(library.allTracks().isEmpty)
        #expect(library.recentlyPlayedTracks().map(\.id) == [playable.id])
        let saved = try await search.importAsTrack(entry: entry)
        #expect(saved.id == playable.id)
        #expect(library.allTracks().map(\.id) == [playable.id])
        #expect(library.track(by: playable.id)?.playCount == 1)
        _ = try await search.resolveTrack(entry: entry)
        #expect(library.allTracks().count == 1)
    }

    @Test("Like promotes membership; unlike keeps Songs and the original UUID")
    func likeThenUnlike() async throws {
        let container = try makeModelContainer(inMemory: true)
        let search = YouTubeSearchService(bridge: MockImportBridge(), modelContainer: container)
        let library = LibraryService(modelContainer: container)
        let track = try await search.resolveTrack(entry: .init(id: "lY5V4hSLWY8", title: "Song"))
        library.toggleLike(id: track.id)
        #expect(library.isLiked(id: track.id))
        #expect(library.allTracks().map(\.id) == [track.id])
        library.toggleLike(id: track.id)
        #expect(!library.isLiked(id: track.id))
        #expect(library.allTracks().map(\.id) == [track.id])
    }

    @Test("Absent membership defaults to saved, and all membership states survive reopening")
    func diskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "membership.sqlite")
        let oldID = UUID(), playableID = UUID()
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: store)
            let context = ModelContext(container)
            let old = Track(id: oldID, title: "Existing", artist: "Artist", youTubeId: "lY5V4hSLWY8", playCount: 7, liked: true)
            old.libraryMember = nil
            old.releaseCatalogID = "album:historical"
            context.insert(old)
            context.insert(Track(id: playableID, title: "Playable", artist: "Channel", youTubeId: "dQw4w9WgXcQ", isInLibrary: false))
            try context.save()
        }
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: store)
            let library = LibraryService(modelContainer: container)
            #expect(library.allTracks().map(\.id) == [oldID])
            #expect(library.allTracks(search: "Existing").map(\.id) == [oldID])
            #expect(library.track(by: playableID)?.isInLibrary == false)
            #expect(library.track(by: oldID)?.liked == true)
            #expect(library.track(by: oldID)?.playCount == 7)
            #expect(library.track(by: oldID)?.releaseCatalogID == "album:historical")
        }
    }

    @Test("Editing display metadata neither invents nor overwrites catalog identity")
    func metadataDoesNotInventIdentity() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let track = Track(title: "Song", artist: "Old", youTubeId: "lY5V4hSLWY8")
        context.insert(track)
        try context.save()
        let library = LibraryService(modelContainer: container)
        library.updateTrack(id: track.id, title: "Song", artist: "Same name", albumTitle: "Same album", albumArtist: nil, trackNo: nil, discNo: nil, year: nil, genre: nil, lyrics: nil)
        #expect(library.track(by: track.id)?.artistCatalogID == nil)
        #expect(library.track(by: track.id)?.releaseCatalogID == nil)
    }
}
