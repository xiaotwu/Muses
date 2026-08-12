import Foundation
import Observation

/// 睡眠定时器:倒计时结束后自动暂停播放。
///
/// `@MainActor @Observable`,UI 可直接绑定 `isActive` / `remainingSeconds`。
/// 用 `Task` + `Task.sleep` 实现每秒递减;`cancel()` 终止。
@Observable
@MainActor
final class SleepTimerService {
    private let playbackService: PlaybackService
    private var timerTask: Task<Void, Never>?

    /// 是否正在倒计时。
    private(set) var isActive = false
    /// 剩余秒数。
    private(set) var remainingSeconds: Double = 0
    /// 设定总秒数。
    private(set) var totalSeconds: Double = 0

    init(playbackService: PlaybackService) {
        self.playbackService = playbackService
    }

    /// 启动定时器。
    /// - Parameter minutes: 定时分钟数(15/30/45/60 等)。
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
                    // Task 被 cancel — 退出循环
                    return
                }
                guard !Task.isCancelled else { return }
                s.remainingSeconds -= 1
            }
            // 倒计时结束 → 暂停播放
            self?.playbackService.pause()
            self?.isActive = false
            self?.remainingSeconds = 0
        }
    }

    /// 取消定时器(不暂停播放)。
    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        isActive = false
        remainingSeconds = 0
        totalSeconds = 0
    }

    /// 格式化剩余时间为 `H:MM:SS` 或 `M:SS`。
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