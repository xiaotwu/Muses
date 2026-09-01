import Foundation
import Observation

/// Sleep timer: automatically pauses playback when the countdown ends.
///
/// `@MainActor @Observable`; the UI can bind `isActive` / `remainingSeconds` directly.
/// Implemented with a `Task` + `Task.sleep` ticking once per second; `cancel()` stops it.
@Observable
@MainActor
final class SleepTimerService {
    private let playbackService: PlaybackService
    private var timerTask: Task<Void, Never>?

    /// Whether the countdown is running.
    private(set) var isActive = false
    /// Seconds remaining.
    private(set) var remainingSeconds: Double = 0
    /// Total configured seconds.
    private(set) var totalSeconds: Double = 0

    init(playbackService: PlaybackService) {
        self.playbackService = playbackService
    }

    /// Starts the timer.
    /// - Parameter minutes: Minutes to count down (e.g. 15/30/45/60).
    func start(minutes: Int) {
        cancel()
        totalSeconds = Double(minutes * 60)
        remainingSeconds = totalSeconds
        isActive = true

        timerTask = Task { [weak self] in
            while let s = self, s.remainingSeconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Task was cancelled — exit the loop
                    return
                }
                guard !Task.isCancelled else { return }
                s.remainingSeconds -= 1
            }
            // Countdown finished → pause playback
            self?.playbackService.pause()
            self?.isActive = false
            self?.remainingSeconds = 0
        }
    }

    /// Cancels the timer (playback is not paused).
    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        isActive = false
        remainingSeconds = 0
        totalSeconds = 0
    }

    /// Formats the remaining time as `H:MM:SS` or `M:SS`.
    var remainingFormatted: String {
        let total = Int(remainingSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}