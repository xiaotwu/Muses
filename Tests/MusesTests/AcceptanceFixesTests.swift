import Testing
import Foundation
import SwiftData
@testable import Muses

/// Product-acceptance fixes: navigation policy, store fallback signaling,
/// bilingual user-facing errors, and Reduce Motion animation helpers.
@MainActor
struct AcceptanceFixesTests {

    @Test("sidebar destinations other than Playlists clear every pushed detail")
    func sidebarPolicyClearsAllExceptPlaylists() {
        for section in SidebarSection.allCases where section != .playlists {
            #expect(SidebarDetailClearPolicy.policy(for: section) == .clearAll)
        }
        #expect(SidebarDetailClearPolicy.policy(for: .playlists) == .keepPlaylistContext)
    }

    @Test("fresh on-disk store does not report in-memory fallback")
    func freshStoreIsNotFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "muses-acc-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = makeModelContainerWithFallback(
            storeURL: dir.appending(path: "muses-youtube-native.sqlite"))
        #expect(!result.usedInMemoryFallback)
        let ctx = ModelContext(result.container)
        ctx.insert(Track(title: "t", artist: "a", durationMs: 1, youTubeId: "test-video"))
        try ctx.save()
    }

    @Test("unreadable store falls back to in-memory and reports the flag")
    func corruptStoreReportsFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "muses-acc-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "muses-youtube-native.sqlite")
        try Data("this is not a sqlite database".utf8).write(to: store)
        let result = makeModelContainerWithFallback(storeURL: store)
        #expect(result.usedInMemoryFallback)
        let ctx = ModelContext(result.container)
        ctx.insert(Track(title: "temp", artist: "a", durationMs: 1, youTubeId: "test-video"))
        try ctx.save()
        #expect(FileManager.default.fileExists(atPath: store.path), "original store must not be deleted")
    }

    @Test("Reduce Motion disables overlay and drawer animations")
    func reduceMotionNilsChromeAnimations() {
        #expect(MusesMotion.drawerAnimation(reduceMotion: true) == nil)
        #expect(MusesMotion.overlayAnimation(reduceMotion: true) == nil)
        #expect(MusesMotion.drawerAnimation(reduceMotion: false) != nil)
        #expect(MusesMotion.overlayAnimation(reduceMotion: false) != nil)
    }

    @Test("cookie source labels are bilingual")
    func cookieSourceDisplayNameBilingual() {
        let none = YTCookieSource.none.displayName
        #expect(none == "None" || none == "不使用")
        let file = YTCookieSource.file.displayName
        #expect(file == "Cookie File" || file == "Cookie 文件")
    }

    @Test("playback errors are bilingual")
    func playerErrorBilingual() {
        let desc = PlayerError.sourceUnavailable.errorDescription
        #expect(desc == "Audio source unavailable (removed or restricted)"
                || desc == "音频源不可用(下架或受限)")
    }

    @Test("creating a playlist posts musesPlaylistsChanged")
    func createPostsPlaylistsChanged() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = PlaylistService(modelContainer: container)
        nonisolated(unsafe) var posted = false
        let observer = NotificationCenter.default.addObserver(
            forName: .musesPlaylistsChanged, object: nil, queue: .main
        ) { _ in
            posted = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = service.create(name: "Posted")
        #expect(posted)
    }

    @Test("YouTube playback context keeps the playing id and sibling youTubeIds")
    func youtubePlaybackContext() {
        let playing = TrackSnapshot(
            id: UUID(), title: "Hit", artist: "A", albumTitle: nil,
            durationSeconds: 10, youTubeId: "video00000b",
            artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        let entries = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "video00000a", title: "A", uploader: "U"),
            YTDlpBridge.YTDlpPlaylistEntry(id: "video00000b", title: "Hit", uploader: "A"),
            YTDlpBridge.YTDlpPlaylistEntry(id: "video00000c", title: "C", uploader: "U")
        ]
        let context = TrackSnapshot.playbackContext(playing: playing, youTubeEntries: entries)
        guard context.count == 3 else { Issue.record("Expected three playable siblings"); return }
        #expect(context[1].id == playing.id)
        #expect(context.map(\.youTubeId) == ["video00000a", "video00000b", "video00000c"])
        let repeated = TrackSnapshot.playbackContext(playing: playing, youTubeEntries: [entries[1], entries[0], entries[1]], selectedIndex: 2)
        #expect(repeated[2].id == playing.id)
        #expect(repeated[0].id != playing.id)
        #expect(repeated[0].youTubeId == repeated[2].youTubeId)
        let queue = QueueService()
        queue.play(playing, context: repeated, from: .search)
        #expect(queue.currentIndex == 2)
    }
}
