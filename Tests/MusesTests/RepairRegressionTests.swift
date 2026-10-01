import AppKit
import Foundation
import SwiftData
import Testing
@testable import Muses

@MainActor
@Suite("Playback and presentation repairs", .serialized)
struct RepairRegressionTests {
    private func binary(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "muses-runner-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "worker")
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Runner did not reach the expected state")
    }

    @Test("Cancelling a running extraction frees its slot without waiting for timeout")
    func cancelRunning() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "muses-started-\(UUID())")
        let file = try binary("echo started > '\(marker.path)'\nexec sleep 20\n")
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
        }
        let runner = YTDlpRunner(maxConcurrent: 1)
        let task = Task { try await runner.run(executablePath: file.path, args: [], timeout: 25) }
        try await waitFor { await runner.inFlightCount == 1 }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled process succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(await runner.inFlightCount == 0)
    }

    @Test("Cancelled queued extraction never launches or retains a slot")
    func cancelWaiting() async throws {
        let file = try binary("exec sleep 20\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let runner = YTDlpRunner(maxConcurrent: 1)
        let active = Task { try await runner.run(executablePath: file.path, args: [], timeout: 25) }
        try await waitFor { await runner.inFlightCount == 1 }
        let queued = Task { try await runner.run(executablePath: file.path, args: [], timeout: 25) }
        try await waitFor { await runner.waitingCount == 1 }
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Cancelled waiter succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await runner.waitingCount == 0)
        active.cancel()
        _ = try? await active.value
        #expect(await runner.inFlightCount == 0)
    }

    @Test("Current selection bypasses occupied background extraction slots")
    func foregroundLane() async throws {
        let slow = try binary("exec sleep 20\n")
        let fast = try binary("echo ready\n")
        defer {
            try? FileManager.default.removeItem(at: slow.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fast.deletingLastPathComponent())
        }
        let runner = YTDlpRunner(maxConcurrent: 1)
        let background = Task { try await runner.run(executablePath: slow.path, args: [], timeout: 25) }
        try await waitFor { await runner.inFlightCount == 1 }
        let start = ContinuousClock.now
        let result = try await YTDlpRequestPriority.$interactive.withValue(true) {
            try await runner.run(executablePath: fast.path, args: [], timeout: 2)
        }
        #expect(result.stdout == "ready")
        #expect(start.duration(to: .now) < .seconds(2))
        background.cancel()
        _ = try? await background.value
    }

    @Test("Media keys toggle once and ignore release/repeat/volume")
    func mediaKeyEdges() {
        #expect(MediaKeyPolicy.action(data1: (16 << 16) | 0x0a00) == CommandRegistry.togglePlayback)
        #expect(MediaKeyPolicy.isInitialPress(data1: (16 << 16) | 0x0a00))
        #expect(!MediaKeyPolicy.isInitialPress(data1: (16 << 16) | 0x0b00))
        #expect(!MediaKeyPolicy.isInitialPress(data1: (16 << 16) | 0x0a01))
        #expect(MediaKeyPolicy.action(data1: (0 << 16) | 0x0a00) == nil)
    }

    @Test("Swipes respect threshold, direction and disabled actions")
    func gestureDirections() {
        #expect(PlayerGesturePolicy.action(x: 2, y: 70, close: true, tracks: false, lyrics: false) == .close)
        #expect(PlayerGesturePolicy.action(x: 2, y: 35, close: true, tracks: true, lyrics: true) == nil)
        #expect(PlayerGesturePolicy.action(x: -80, y: 0, close: true, tracks: true, lyrics: false) == .next)
        #expect(PlayerGesturePolicy.action(x: 80, y: 0, close: true, tracks: false, lyrics: false) == nil)
    }

    @Test("Return consumes the same swipe and momentum but releases the next gesture")
    func returnGestureTail() {
        var tail = PlayerGestureTailState()
        tail.begin(at: 10)
        let results = [
            tail.consume(at: 10, newGesture: true, precise: true),
            tail.consume(at: 10.05, newGesture: false, precise: true),
            tail.consume(at: 10.10, newGesture: false, precise: true),
            tail.consume(at: 10.35, newGesture: false, precise: true),
            tail.consume(at: 10.40, newGesture: true, precise: true),
            tail.consume(at: 10.45, newGesture: false, precise: true)
        ]
        #expect(results == [true, true, true, true, false, false])
        tail.begin(at: 20)
        let expired = tail.consume(at: 20.5, newGesture: false, precise: true)
        #expect(!expired)
    }

    @Test("Physical swipe direction is independent of the natural-scrolling preference")
    func naturalScrollingDirections() {
        let natural = PlayerGesturePolicy.fingerDelta(80, invertedFromDevice: true)
        let traditional = PlayerGesturePolicy.fingerDelta(-80, invertedFromDevice: false)
        #expect(natural == traditional)
        #expect(PlayerGesturePolicy.action(x: 0, y: natural, close: true, tracks: false, lyrics: false) == .close)
        #expect(PlayerGesturePolicy.action(x: 0, y: traditional, close: true, tracks: false, lyrics: false) == .close)
    }

    @Test("Official imported album displays lazy tracks in source order")
    func lazyAlbum() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(playlistId: "OLAK5uy_repair", url: "https://music.youtube.com/playlist?list=OLAK5uy_repair",
                                     title: "Imported Album", channel: "Publisher")
        context.insert(imported)
        let first = YouTubeImportItem(youTubeId: "abcdefghijk", title: "Z first", artist: "Performer", durationMs: 2000, order: 0)
        let second = YouTubeImportItem(youTubeId: "lmnopqrstuv", title: "A second", artist: "Performer", durationMs: 2000, order: 1)
        context.insert(first); context.insert(second)
        first.import_ = imported; second.import_ = imported; imported.items = [second, first]
        try context.save()
        let albums = YouTubeCatalogService(modelContainer: container).releases()
        #expect(albums.count == 1)
        #expect(albums.first?.tracks.map(\.title) == ["Z first", "A second"])
        #expect(try context.fetchCount(FetchDescriptor<Track>()) == 0)
    }

    @Test("Music-video markers survive rich song metadata")
    func musicVideo() {
        let entry = YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghijk", title: "Song (Official Music Video)",
                                                track: "Song", album: "Release", artist: "Performer")
        #expect(entry.inferredMediaKind == .musicVideo)
    }

    @Test("Font choice persists and scales the full semantic typography")
    func fontPreferences() throws {
        let name = "repair-font-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = TypographyPreferences(defaults: defaults)
        #expect(preferences.size == .standard)
        preferences.size = .large
        preferences.family = "Georgia"
        let restored = TypographyPreferences(defaults: defaults)
        #expect(restored.size == .large)
        #expect(restored.family == "Georgia")
        #expect(InterfaceTextSize.small.scale < 1)
        #expect(InterfaceTextSize.large.scale > 1)
    }

    @Test("Display credits use video metadata and preserve manual artist edits")
    func credits() {
        let cache = SongCreditCache()
        let snapshot = TrackSnapshot(id: UUID(), title: "Song", artist: "My account", albumTitle: nil,
            durationSeconds: 10, youTubeId: "repairvid01", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        cache.recordOwner("My account", videoID: snapshot.youTubeId)
        cache.store(.init(id: snapshot.youTubeId, title: "Song", uploader: "Video publisher", artist: "Performer"))
        #expect(cache.artist(snapshot: snapshot) == "Performer")
        #expect(snapshot.artist == "My account")
        let edited = LyricsSearchQuery(title: snapshot.title, artist: "My correction").applying(to: snapshot)
        #expect(cache.artist(snapshot: edited) == "My correction")
    }
}
