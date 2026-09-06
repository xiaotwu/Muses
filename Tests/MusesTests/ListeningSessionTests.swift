import Testing
import Foundation
import SwiftData
@testable import Muses

/// Listening Sessions + Crash Recovery acceptance (Final Spec §10.5):
/// - `ListeningSession` @Model persists + status computed properties;
/// - `SessionService` subscribes to the event bus: `trackStarted` opens/continues the active session and writes the crash-recovery slot,
///   `trackSeeked` updates the position, and `trackCompleted` (queue drained) ends the session;
/// - The feature flag prevents persistence and restoration when disabled.
/// - Launch restoration loads the existing queue item, seeks to the persisted
///   position, and stays paused without presenting a decision dialog.
/// - Older active sessions remain restorable and never replace the saved queue.
/// - Uses a stub engine (RecordingEngine) to avoid the headless AVAudioPlayerNode IO-cycle exception.
@Suite("Listening Sessions")
@MainActor
struct ListeningSessionTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ title: String, id: UUID = UUID(),
                      durationSec: Double = 200) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: "Artist \(title)",
                      albumTitle: "Album \(title)", durationSeconds: durationSec,
                      youTubeId: "test-video",
                      artworkUrl: nil,
                      sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
    }

    /// Builds a `QueueService` bound to `modelContext` (for persist/restore).
    private func makeQueue(container: ModelContainer) -> QueueService {
        let q = QueueService()
        q.modelContext = container.mainContext
        return q
    }

    private func makePlayback(queue: QueueService) -> (PlaybackService, RecordingEngine) {
        let engine = RecordingEngine()
        let svc = PlaybackService(youtubeEngine: engine, queue: queue)
        return (svc, engine)
    }

    private func fetchSessions(_ container: ModelContainer) -> [ListeningSession] {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<ListeningSession>())) ?? []
    }

    private func queueStateRow(_ container: ModelContainer) -> QueueState? {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<QueueState>()))?
            .first(where: { $0.id == QueueState.sharedID })
    }

    // MARK: - Model

    @Test("ListeningSession persistence round trip and status computed property")
    func sessionRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let s = ListeningSession(startedAt: Date(timeIntervalSince1970: 1000),
                                 status: .active, currentTrackId: UUID(),
                                 currentPositionMs: 12_000)
        ctx.insert(s)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<ListeningSession>()).first
        #expect(fetched?.status == .active)
        #expect(fetched?.currentPositionMs == 12_000)
        #expect(fetched?.currentTrackId != nil)
        #expect(fetched?.endedAt == nil)
    }

    @Test("ListeningSession table included in schema (empty query succeeds)")
    func schemaIncludesListeningSession() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<ListeningSession>()).isEmpty)
    }

    // MARK: - Events → session lifecycle

    @Test("trackStarted opens active session and checkpoints crash-recovery slot at position 0")
    func trackStartedOpensSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let id = UUID()
        bus.post(.trackStarted(snap("A", id: id)))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].status == .active)
        #expect(sessions[0].currentTrackId == id)
        #expect(sessions[0].currentPositionMs == 0)
        // The crash-recovery slot is written synchronously into the single QueueState row
        let row = queueStateRow(container)
        #expect(row?.currentTrackId == id)
        #expect(row?.lastPositionMs == 0)
        _ = svc
    }

    @Test("Subsequent trackStarted continues same session updating track without inserting new row")
    func subsequentTrackStartedContinuesSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let a = UUID(), b = UUID()
        bus.post(.trackStarted(snap("A", id: a)))
        bus.post(.trackStarted(snap("B", id: b)))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)            // still the same session
        #expect(sessions[0].currentTrackId == b) // current track advanced to B
        #expect(sessions[0].currentPositionMs == 0)
        _ = svc
    }

    @Test("trackSeeked updates session position and crash recovery slot")
    func seekCheckpointsPosition() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        let id = UUID()
        bus.post(.trackStarted(snap("A", id: id)))
        bus.post(.trackSeeked(trackId: id, toMs: 65_000))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].currentPositionMs == 65_000)
        let row = queueStateRow(container)
        #expect(row?.lastPositionMs == 65_000)
        _ = svc
    }

    @Test("trackCompleted with queue exhaustion ends session")
    func completionWithExhaustionEndsSession() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        // Set the queue directly: single item, last position, .off, empty upNext
        let a = snap("A")
        q.items = [QueueItem(id: UUID(), track: a, queuedAt: .init(), fromContext: .songs)]
        q.currentIndex = 0
        q.upNext = []
        q.repeatMode = .off

        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        bus.post(.trackStarted(a))
        #expect(fetchSessions(container).first?.status == .active)
        bus.post(.trackCompleted(a, listenedMs: 200_000))

        let sessions = fetchSessions(container)
        #expect(sessions.count == 1)
        #expect(sessions[0].status == .ended)
        #expect(sessions[0].endedAt != nil)
        _ = svc
    }

    @Test("trackCompleted keeps session active when queue has next track")
    func completionWithoutExhaustionKeepsActive() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        let a = snap("A"), b = snap("B")
        q.items = [
            QueueItem(id: UUID(), track: a, queuedAt: .init(), fromContext: .songs),
            QueueItem(id: UUID(), track: b, queuedAt: .init(), fromContext: .songs)
        ]
        q.currentIndex = 0
        q.upNext = []
        q.repeatMode = .off

        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        bus.post(.trackStarted(a))
        bus.post(.trackCompleted(a, listenedMs: 200_000))
        #expect(fetchSessions(container).first?.status == .active)
        _ = svc
    }

    // MARK: - Feature flag gating

    @Test("ffSessions disabled: trackStarted does not persist or load restore track")
    func disabledFlagNoOps() async throws {
        let container = try makeContainer()
        let restored = snap("Restored")
        seedRestorable(container: container, track: restored, positionMs: 12_000)
        let bus = PlaybackEventBus()
        let q = makeQueue(container: container)
        q.restore()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { false })

        bus.post(.trackStarted(snap("A")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fetchSessions(container).count == 1)
        #expect(local.loadCallCount == 0)
        _ = svc
    }

    // MARK: - Startup restore

    private func seedRestorable(container: ModelContainer, track: TrackSnapshot,
                                positionMs: Double, updatedAt: Date = .init()) {
        let ctx = ModelContext(container)
        // Single queue row: contains the track, currentIndex 0 + crash-recovery slot
        let itemsJSON = (try? String(data: JSONEncoder().encode(
            [QueueItem(id: UUID(), track: track, queuedAt: .init(), fromContext: .songs)]),
            encoding: .utf8)) ?? "[]"
        let row = QueueState(itemsJSON: itemsJSON, currentIndex: 0,
                            upNextJSON: "[]", historyJSON: "[]",
                            repeatModeRaw: RepeatMode.off.rawValue, shuffle: false,
                            currentTrackId: track.id, lastPositionMs: positionMs)
        ctx.insert(row)
        // Active session row
        let session = ListeningSession(startedAt: updatedAt.addingTimeInterval(-60),
                                       updatedAt: updatedAt, status: .active,
                                       currentTrackId: track.id, currentPositionMs: positionMs)
        ctx.insert(session)
        try? ctx.save()
    }

    @Test("Startup restore: loads last position paused")
    func restoreLoadsPausedAtPosition() async throws {
        let container = try makeContainer()
        let track = snap("LateNight", id: UUID())
        seedRestorable(container: container, track: track, positionMs: 65_000)

        let q = makeQueue(container: container)
        q.restore()  // mirrors MusesApp: restore the queue first
        #expect(q.current()?.track.id == track.id)
        #expect(q.lastPositionMs == 65_000)

        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        try await Task.sleep(for: .milliseconds(150))
        #expect(local.loadCallCount == 1)
        #expect(local.lastLoadedTrack?.id == track.id)
        #expect(abs((local.lastSeekTime ?? -1) - 65.0) < 0.01)
        #expect(local.playCallCount == 0)
        #expect(!playback.state.isPlaying)
        #expect(svc.currentSessionId != nil)
        _ = svc
    }

    @Test("Automatic restore does not trigger playback history lifecycle")
    func automaticRestoreDoesNotStartPlayback() async throws {
        let container = try makeContainer()
        let track = snap("Resume", id: UUID(), durationSec: 200)
        seedRestorable(container: container, track: track, positionMs: 65_000)

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        try await Task.sleep(for: .milliseconds(150))

        #expect(local.loadCallCount == 1)
        #expect(local.playCallCount == 0)
        #expect(fetchSessions(container).count == 1)
        #expect(fetchSessions(container).first?.status == .active)
        _ = svc
    }

    @Test("Automatic restore position clamps when exceeding duration minus 2s")
    func automaticRestoreClampsToDurationMinus2() async throws {
        let container = try makeContainer()
        let track = snap("Resume", id: UUID(), durationSec: 200)
        seedRestorable(container: container, track: track, positionMs: 210_000)  // 210s > 198s

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        // RecordingEngine.load does not set duration (the real engine reads it from the audio file).
        // Inject duration manually so PlaybackService's clamp condition `state.duration > 0` holds,
        // using the same stub-injection technique as ListeningHistoryTests.
        local.state.duration = 200
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        try await Task.sleep(for: .milliseconds(150))

        // clamps to duration(200) - 2 = 198s
        #expect(abs((local.lastSeekTime ?? -1) - 198.0) < 0.01)
        _ = svc
    }

    @Test("Stale session still restores last position paused")
    func olderSessionStillRestoresPaused() async throws {
        let container = try makeContainer()
        let track = snap("Stale", id: UUID())
        let stale = Date().addingTimeInterval(-3 * 3600)  // 3h ago
        seedRestorable(container: container, track: track, positionMs: 10_000, updatedAt: stale)

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        try await Task.sleep(for: .milliseconds(150))
        #expect(local.loadCallCount == 1)
        #expect(abs((local.lastSeekTime ?? -1) - 10.0) < 0.01)
        #expect(local.playCallCount == 0)
        let sessions = fetchSessions(container)
        #expect(sessions.first?.status == .active)
        _ = svc
    }

    @Test("Crash recovery with multiple active sessions keeps only latest and ends remainder")
    func multipleActiveCollapsesToLatest() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let track = snap("Multi", id: UUID())
        let itemsJSON = (try? String(data: JSONEncoder().encode(
            [QueueItem(id: UUID(), track: track, queuedAt: .init(), fromContext: .songs)]),
            encoding: .utf8)) ?? "[]"
        let row = QueueState(itemsJSON: itemsJSON, currentIndex: 0,
                            upNextJSON: "[]", historyJSON: "[]",
                            repeatModeRaw: RepeatMode.off.rawValue, shuffle: false,
                            currentTrackId: track.id, lastPositionMs: 5_000)
        ctx.insert(row)
        // Two active sessions: old + new
        let older = ListeningSession(startedAt: Date().addingTimeInterval(-7200),
                                      updatedAt: Date().addingTimeInterval(-7100), status: .active)
        let newer = ListeningSession(startedAt: Date().addingTimeInterval(-600),
                                      updatedAt: Date().addingTimeInterval(-500), status: .active,
                                      currentTrackId: track.id, currentPositionMs: 5_000)
        ctx.insert(older); ctx.insert(newer)
        try? ctx.save()

        let q = makeQueue(container: container)
        q.restore()
        let bus = PlaybackEventBus()
        let (playback, _) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })

        try await Task.sleep(for: .milliseconds(150))
        let actives = fetchSessions(container).filter { $0.status == .active }
        #expect(actives.count == 1)
        #expect(playback.state.track?.id == track.id)
        #expect(!playback.state.isPlaying)
        _ = svc
    }

    @Test("No restorable session does not load track")
    func noRestorableSessionDoesNotLoad() async throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        // Seed no sessions/queue
        let bus = PlaybackEventBus()
        let (playback, local) = makePlayback(queue: q)
        let svc = SessionService(modelContainer: container, eventBus: bus,
                                 playback: playback, queue: q, enabledProvider: { true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(local.loadCallCount == 0)
        #expect(playback.state.track == nil)
        _ = svc
    }
}
