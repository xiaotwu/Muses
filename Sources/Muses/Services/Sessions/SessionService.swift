import Foundation
import SwiftData
import AppKit

/// Listening-session checkpoints and crash recovery.
///
/// An active session records the queue identity and current position. On the
/// next launch the already-restored queue is loaded at that position without
/// starting playback; the user remains in control of when audio resumes.
@Observable
@MainActor
final class SessionService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let playback: PlaybackService
    private let queue: QueueService
    private let enabledProvider: () -> Bool
    private var subscription: UUID?
    private var checkpointTimer: Task<Void, Never>?
    /// System observer tokens live in a dedicated `@unchecked Sendable` box: SessionService is a `@MainActor`
    /// class with a nonisolated deinit that must call removeObserver. The box is a `let` (readable off the actor),
    /// with interior mutability managed manually (installed on the main thread, read only in deinit), hence `@unchecked Sendable`.
    private let observerTokens = ObserverTokens()

    /// Current active session id (in-memory mirror, avoiding a store lookup per event). nil = no session in progress.
    private var activeSessionId: UUID?
    /// Read-only access to the in-progress session id (FocusService links FocusSession.listeningSessionId to it).
    var currentSessionId: UUID? { activeSessionId }
    /// Playback state before sleep, used on wake to decide whether to resume playback.
    private var wasPlayingBeforeSleep = false

    var isEnabled: Bool { enabledProvider() }

    /// `enabledProvider` reads `UserDefaults` live in production; tests inject a fixed value for isolation.
    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         playback: PlaybackService, queue: QueueService,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffSessions)
    }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.playback = playback
        self.queue = queue
        self.enabledProvider = enabledProvider
        subscribe()
        startCheckpointTimer()
        installSystemObservers()
        checkForRestorableSession()
    }

    deinit {
        // Only the observer registration needs cleanup; eventBus subscriptions hold `[weak self]` and become no-ops once released,
        // and the checkpoint timer is likewise a `[weak self]` loop that exits on its next `guard let self`.
        // removeObserver is a thread-safe ObjC call, safe to use from the nonisolated deinit.
        let tokens = observerTokens
        if let o = tokens.sleep { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = tokens.wake { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = tokens.terminate { NotificationCenter.default.removeObserver(o) }
    }

    /// Observer token container: mutable properties installed on the main thread by `SessionService` and read in deinit,
    /// with concurrency managed manually — hence `@unchecked Sendable` (nonisolated deinit reading the `let` box itself is safe).
    final class ObserverTokens: @unchecked Sendable {
        var sleep: NSObjectProtocol?
        var wake: NSObjectProtocol?
        var terminate: NSObjectProtocol?
    }

    // MARK: - Event subscription

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: PlaybackEvent) {
        guard isEnabled else { return }
        switch event {
        case .trackStarted(let snap):
            openOrContinueSession(for: snap)
        case .trackPaused, .trackStopped, .trackSkipped:
            checkpoint()
        case .trackCompleted:
            checkpoint()
            // Queue exhausted (repeat off, last track, no inserted item) → end the session naturally
            if queue.repeatMode == .off,
               queue.currentIndex >= queue.items.count - 1,
               queue.upNext.isEmpty {
                endActiveSession()
            }
        case .trackSeeked(_, let toMs):
            checkpoint(positionMs: toMs)
        case .trackResumed:
            break  // Resuming playback does not change track/position boundaries; the periodic timer keeps checkpointing
        case .queueChanged, .outputDeviceChanged,
             .focusSessionStarted, .focusSessionEnded:
            break
        }
    }

    // MARK: - Session lifecycle

    /// Track start: continue the current active session (update track + snapshot) or create a new one.
    private func openOrContinueSession(for snap: TrackSnapshot) {
        let ctx = ModelContext(modelContainer)
        if let sid = activeSessionId,
           let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }), row.status == .active {
            row.currentTrackId = snap.id
            row.currentPositionMs = 0
            row.updatedAt = Date()
            row.queueSnapshotJSON = snapshotQueueJSON()
            try? ctx.save()
        } else {
            let session = ListeningSession(
                startedAt: Date(), status: .active,
                queueSnapshotJSON: snapshotQueueJSON(),
                currentTrackId: snap.id, currentPositionMs: 0)
            ctx.insert(session)
            try? ctx.save()
            activeSessionId = session.id
        }
        // Sync the crash-recovery slot to the new track (position 0)
        queue.checkpointPosition(currentTrackId: snap.id, lastPositionMs: 0)
    }

    /// Checkpoint: writes the current position into the session row and the `QueueState` crash-recovery slot.
    /// Uses an explicitly passed `positionMs` when provided (seek events carry their target); otherwise converts from `playback.state.position`.
    private func checkpoint(positionMs: Double? = nil) {
        guard let sid = activeSessionId else { return }
        let posMs = positionMs ?? (max(0, playback.state.position) * 1000.0)
        let trackId = playback.state.track?.id
        let ctx = ModelContext(modelContainer)
        guard let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }) else { return }
        row.currentPositionMs = posMs
        row.currentTrackId = trackId
        row.updatedAt = Date()
        try? ctx.save()
        // The crash-recovery slot (single QueueState row) is what launch recovery actually reads.
        queue.checkpointPosition(currentTrackId: trackId, lastPositionMs: posMs)
    }

    /// Ends the current active session (queue exhausted / user "Start Over").
    private func endActiveSession() {
        guard let sid = activeSessionId else { return }
        let ctx = ModelContext(modelContainer)
        if let row = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?
            .first(where: { $0.id == sid }) {
            row.statusRaw = SessionStatus.ended.rawValue
            row.endedAt = Date()
            row.updatedAt = Date()
            try? ctx.save()
        }
        activeSessionId = nil
    }

    /// Self-contained queue snapshot (for session review/audit; crash recovery reads the single QueueState row, not this snapshot).
    private func snapshotQueueJSON() -> String? {
        let snap = QueueSnapshotPayload(
            items: queue.items, upNext: queue.upNext, history: queue.history,
            currentIndex: queue.currentIndex,
            repeatMode: queue.repeatMode.rawValue, shuffle: queue.shuffle)
        return try? String(data: JSONEncoder().encode(snap), encoding: .utf8)
    }

    private struct QueueSnapshotPayload: Codable {
        let items: [QueueItem]
        let upNext: [QueueItem]
        let history: [QueueItem]
        let currentIndex: Int
        let repeatMode: String
        let shuffle: Bool
    }

    // MARK: - Periodic checkpoint (only while playing, ~10s)

    private func startCheckpointTimer() {
        checkpointTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                guard self.isEnabled,
                      self.activeSessionId != nil,
                      self.playback.state.isPlaying,
                      self.playback.state.track != nil else { continue }
                self.checkpoint()
            }
        }
    }

    // MARK: - Launch recovery

    /// Adopt the newest active session and restore its queue position paused.
    /// QueueService.restore() runs before this service is constructed.
    private func checkForRestorableSession() {
        guard isEnabled else { return }
        let ctx = ModelContext(modelContainer)
        var desc = FetchDescriptor<ListeningSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        desc.fetchLimit = 64
        let sessions = (try? ctx.fetch(desc)) ?? []
        let active = sessions.filter { $0.status == .active }
        guard let latest = active.first else { return }
        // Defensive: a crash may leave several active sessions; close the extras.
        for extra in active.dropFirst() {
            extra.statusRaw = SessionStatus.ended.rawValue
            extra.endedAt = Date()
        }
        try? ctx.save()
        guard queue.current() != nil else { return }
        let posMs = queue.lastPositionMs ?? latest.currentPositionMs ?? 0
        activeSessionId = latest.id
        playback.restoreCurrentPaused(atMs: posMs)
    }

    // MARK: - System events (sleep / wake / terminate)

    private func installSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let tokens = observerTokens
        tokens.sleep = ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleSleep() } }
        tokens.wake = ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleWake() } }
        tokens.terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleTerminate() } }
    }

    private func handleSleep() {
        guard isEnabled else { return }
        wasPlayingBeforeSleep = playback.state.isPlaying
        checkpoint()
    }

    private func handleWake() {
        guard isEnabled else { return }
        // Best-effort resync: was playing before sleep and currently stopped → resume playback.
        if wasPlayingBeforeSleep,
           playback.state.track != nil,
           !playback.state.isPlaying {
            playback.toggle()
        }
        checkpoint()
    }

    private func handleTerminate() {
        guard isEnabled else { return }
        checkpoint()
    }
}
