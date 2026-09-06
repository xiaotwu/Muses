import Testing
import Foundation
@testable import Muses

/// Pure-logic tests for the playlist sidebar merge adapter and YouTube link detection.
/// No SwiftData persistence container is touched: only un-inserted @Model instances are built to read properties.
@Suite("Phase D1 — Playlist sidebar adapter & link detection")
struct PlaylistSidebarAdapterTests {

    // MARK: - PlaylistSidebarAdapter.merged

    @Test("merged: Local and YouTube merged, pinned on top, remainder in reverse chronological order")
    func mergedSortsPinnedFirstThenDateDesc() {
        let now = Date()
        let localOld = Playlist(name: "Old", createdAt: now.addingTimeInterval(-3600), pinned: false)
        let localNew = Playlist(name: "New", createdAt: now, pinned: false)
        let localPinned = Playlist(name: "Pinned", createdAt: now.addingTimeInterval(-7200), pinned: true)
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c",
                               importedAt: now.addingTimeInterval(-1800))

        let merged = PlaylistSidebarAdapter.merged(local: [localOld, localNew, localPinned], youTube: [yt])

        // Pinned items sort to the top, the rest by sortDate descending: New (0) > YT (-1800) > Old (-3600)
        #expect(merged.count == 4)
        #expect(merged[0].name == "Pinned")
        #expect(merged[1].name == "New")
        #expect(merged[2].name == "YT")
        #expect(merged[3].name == "Old")
    }

    @Test("merged: YouTube items mark origin=.youtube and isYouTube=true")
    func mergedYouTubeOriginFlag() {
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c", importedAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [], youTube: [yt])
        #expect(merged.count == 1)
        #expect(merged[0].isYouTube)
        #expect(merged[0].origin == .youtube)
        #expect(merged[0].youTubeImportId == yt.id)
        #expect(merged[0].playlistId == nil)
    }

    @Test("merged: Local items mark origin=.local and carry playlistId")
    func mergedLocalOriginFlag() {
        let p = Playlist(name: "Local", createdAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [p], youTube: [])
        #expect(merged.count == 1)
        #expect(merged[0].origin == .local)
        #expect(merged[0].playlistId == p.id)
        #expect(merged[0].youTubeImportId == nil)
        #expect(!merged[0].isYouTube)
    }

    @Test("merged: IDs unique across origins with prefix separation")
    func mergedIdsUniqueAcrossOrigins() {
        let p = Playlist(name: "Local", createdAt: Date())
        let yt = YouTubeImport(playlistId: "PL1", url: "u", title: "YT", channel: "c", importedAt: Date())
        let merged = PlaylistSidebarAdapter.merged(local: [p], youTube: [yt])
        let ids = Set(merged.map { $0.id })
        #expect(ids.count == 2)
        #expect(merged.contains { $0.id.hasPrefix("pl-") })
        #expect(merged.contains { $0.id.hasPrefix("yt-") })
    }

    // MARK: - YouTubeLinkKind.detect

    @Test("detect: Playlist links with list= parameter")
    func detectPlaylist() {
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/playlist?list=PLxxx") == .playlist)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/watch?v=abc&list=PLyyy") == .playlist)
        #expect(YouTubeLinkKind.detect("https://youtu.be/abc?list=PLzzz") == .playlist)
    }

    @Test("detect: Single video links")
    func detectVideo() {
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/watch?v=abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://youtu.be/abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/shorts/abc123") == .video)
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/embed/abc123") == .video)
    }

    @Test("detect: Invalid, empty, or non-YouTube link returns unknown")
    func detectUnknown() {
        #expect(YouTubeLinkKind.detect("") == .unknown)
        #expect(YouTubeLinkKind.detect("not a url") == .unknown)
        #expect(YouTubeLinkKind.detect("https://example.com/watch?v=abc") == .unknown)
        // /playlist but no list= parameter: the playlist id cannot be determined
        #expect(YouTubeLinkKind.detect("https://www.youtube.com/playlist") == .unknown)
    }
}