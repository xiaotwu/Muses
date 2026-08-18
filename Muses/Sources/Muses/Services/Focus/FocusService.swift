import Foundation
import SwiftData
import Observation

/// 专注模式服务(Final Spec §10.9 Feature 9 — Focus Mode)。
///
/// `@MainActor @Observable`:UI 绑定 `isActive`/`remainingSeconds`/`isQueueLocked` 等。
/// `start(...)` 开启一条 `FocusSession`,可选倒计时(25/45/60/90/custom/no-timer),
/// 到期按 `FocusExpiration` 处理(继续/暂停/仅通知);可选队列锁(前瞻:推荐注入将来加入时
/// 不得替换,手动编辑始终允许);可选轻量 Pomodoro(25 专注 + 5 休息,无任务管理)。
/// 在 `PlaybackEventBus` 上发 `.focusSessionStarted` / `.focusSessionEnded`。
///
/// 功能开关 `PrefKey.ffFocusMode`(默认关):关闭时 `start` 为 no-op,`isActive` 保持 false。
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

    /// 是否处于专注中(UI 绑定此值抑制发现类表面)。
    private(set) var isActive = false
    /// 是否锁定专注会话队列(前瞻;推荐注入将来加入时不得替换)。
    private(set) var isQueueLocked = false
    /// 剩余秒数(0 = 无限时或已结束)。
    private(set) var remainingSeconds: Double = 0
    /// 设定总秒数(0 = 无限时)。
    private(set) var totalSeconds: Double = 0
    /// 到期行为。
    private(set) var expiration: FocusExpiration = .pause
    /// 是否为 Pomodoro 模式(25 专注 + 5 休息循环)。
    private(set) var isPomodoro = false
    /// Pomodoro 当前阶段(.focus / .break)。
    private(set) var pomodoroPhase: PomodoroPhase = .focus
    /// 当前专注会话的持久化 id。
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

    // MARK: - 启停

    /// 开启专注会话。
    /// - Parameters:
    ///   - minutes: 计划专注分钟数。nil = 无限时(直到手动停止)。
    ///   - queueLocked: 是否锁定队列。
    ///   - expiration: 到期行为。
    ///   - pomodoro: 是否启用 Pomodoro(忽略 minutes,固定 25 专注 + 5 休息)。
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

    /// 停止专注会话(手动或到期)。`completedByTimer` 区分自然到时 vs 手动停止。
    func stop(completedByTimer: Bool = false) {
        guard isActive else { return }
        stopTimer()
        isActive = false
        isPomodoro = false
        isQueueLocked = false
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

    // MARK: - 倒计时

    private func startCountdown() {
        guard totalSeconds > 0 else { return }   // 无限时不启动 Task
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
            // Pomodoro:focus 到时 → 提示并切 break(5 分钟),不自动停止;break 到时 → 切 focus。
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
        case .notifyOnly:  break   // 通知策略由调用方/Settings 决定,此处不改播放
        }
    }

    // MARK: - 格式化

    var remainingFormatted: String {
        let total = Int(remainingSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}