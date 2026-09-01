import Foundation
import SwiftData
import Observation

/// Focus mode service (Final Spec §10.9 Feature 9 — Focus Mode).
///
/// `@MainActor @Observable`: the UI binds `isActive`/`remainingSeconds`/`isQueueLocked`, etc.
/// `start(...)` opens a `FocusSession` with an optional countdown
/// (25/45/60/90/custom/no-timer) whose expiry follows `FocusExpiration`
/// (keep playing/pause/notify only); an optional queue lock (forward-looking: recommended
/// injections must not replace future additions, while manual edits are always allowed);
/// and an optional lightweight Pomodoro (25 focus + 5 break, no task management).
/// Posts `.focusSessionStarted` / `.focusSessionEnded` on `PlaybackEventBus`.
///
/// Feature flag `PrefKey.ffFocusMode` (off by default): when off, `start` is a no-op
/// and `isActive` stays false.
@Observable
@MainActor
final class FocusService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let playback: PlaybackService
    private let sessionService: SessionService?
    private let enabledProvider: () -> Bool
    private let nowProvider: () -> Date
    private var timerTask: Task<Void, Never>?

    /// Whether a focus session is active (the UI binds this to suppress discovery surfaces).
    private(set) var isActive = false
    /// Whether the focus session's queue is locked (forward-looking; recommended injections
    /// must not replace future additions).
    private(set) var isQueueLocked = false
    /// Seconds remaining (0 = untimed or finished).
    private(set) var remainingSeconds: Double = 0
    /// Total configured seconds (0 = untimed).
    private(set) var totalSeconds: Double = 0
    /// Expiry behavior.
    private(set) var expiration: FocusExpiration = .pause
    /// Whether Pomodoro mode is on (25 focus + 5 break cycles).
    private(set) var isPomodoro = false
    /// Current Pomodoro phase (.focus / .break).
    private(set) var pomodoroPhase: PomodoroPhase = .focus
    /// Persistent id of the current focus session.
    private(set) var activeSessionId: UUID?
    var isEnabled: Bool { enabledProvider() }

    enum PomodoroPhase: String, Sendable { case focus, break_ }

    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         playback: PlaybackService, sessionService: SessionService? = nil,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffFocusMode)
    },
         nowProvider: @escaping () -> Date = { Date() }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.playback = playback
        self.sessionService = sessionService
        self.enabledProvider = enabledProvider
        self.nowProvider = nowProvider
    }

    // MARK: - Start/stop

    /// Starts a focus session.
    /// - Parameters:
    ///   - minutes: Planned focus minutes. nil = untimed (runs until manually stopped).
    ///   - queueLocked: Whether to lock the queue.
    ///   - expiration: Expiry behavior.
    ///   - pomodoro: Whether to enable Pomodoro (ignores minutes; fixed 25 focus + 5 break).
    func start(minutes: Int?, queueLocked: Bool = false,
               expiration: FocusExpiration = .pause, pomodoro: Bool = false) {
        guard isEnabled else { return }
        stopTimer()
        let plannedMs: Int?
        let totalSec: Double
        if pomodoro {
            isPomodoro = true; pomodoroPhase = .focus
            totalSec = 25 * 60; plannedMs = 25 * 60 * 1000
        } else if let minutes {
            totalSec = Double(minutes * 60); plannedMs = minutes * 60 * 1000
        } else {
            totalSec = 0; plannedMs = nil
        }
        totalSeconds = totalSec
        remainingSeconds = totalSec
        isQueueLocked = queueLocked
        playback.queue.replacementLocked = queueLocked
        self.expiration = expiration
        isActive = true

        let session = FocusSession(startedAt: nowProvider(),
                                    plannedDurationMs: plannedMs,
                                    listeningSessionId: sessionService?.currentSessionId,
                                    status: .active)
        let ctx = ModelContext(modelContainer)
        ctx.insert(session)
        try? ctx.save()
        activeSessionId = session.id
        eventBus.post(.focusSessionStarted)
        startCountdown()
    }

    /// Stops the focus session (manually or on expiry). `completedByTimer` distinguishes
    /// natural expiry from a manual stop.
    func stop(completedByTimer: Bool = false) {
        guard isActive else { return }
        stopTimer()
        isActive = false
        isPomodoro = false
        isQueueLocked = false
        playback.queue.replacementLocked = false
        remainingSeconds = 0
        totalSeconds = 0
        if let sid = activeSessionId {
            let ctx = ModelContext(modelContainer)
            if let s = (try? ctx.fetch(FetchDescriptor<FocusSession>()))?
                .first(where: { $0.id == sid }) {
                s.endedAt = nowProvider()
                s.status = completedByTimer ? .completed : .completed
                try? ctx.save()
            }
        }
        activeSessionId = nil
        eventBus.post(.focusSessionEnded)
    }

    // MARK: - Countdown

    private func startCountdown() {
        guard totalSeconds > 0 else { return }   // untimed sessions need no Task
        timerTask = Task { [weak self] in
            while let s = self, s.remainingSeconds > 0, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                s.remainingSeconds -= 1
            }
            await MainActor.run { self?.handleExpiry() }
        }
    }

    private func stopTimer() {
        timerTask?.cancel(); timerTask = nil
    }

    private func handleExpiry() {
        guard isActive else { return }
        if isPomodoro {
            // Pomodoro: focus expiry → notify and switch to a 5-minute break (no auto-stop); break expiry → back to focus.
            switch pomodoroPhase {
            case .focus:
                pomodoroPhase = .break_
                totalSeconds = 5 * 60; remainingSeconds = 5 * 60
                applyExpiration()
                startCountdown()
                return
            case .break_:
                pomodoroPhase = .focus
                totalSeconds = 25 * 60; remainingSeconds = 25 * 60
                applyExpiration()
                startCountdown()
                return
            }
        }
        applyExpiration()
        stop(completedByTimer: true)
    }

    private func applyExpiration() {
        switch expiration {
        case .keepPlaying: break
        case .pause:       playback.pause()
        case .notifyOnly:  break   // notification policy is decided by the caller/Settings; playback is untouched here
        }
    }

    // MARK: - Formatting

    var remainingFormatted: String {
        let total = Int(remainingSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}