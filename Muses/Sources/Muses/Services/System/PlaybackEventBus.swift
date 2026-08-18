import Foundation

/// 跨特性播放生命周期事件(Phase 16 起为 History / Session / Context / Inbox / Focus
/// 等订阅者提供单一事件源,避免每个特性各自轮询 `PlaybackService.state`)。
///
/// 设计:`@MainActor` 单例(由 `PlaybackService` 持有),`post` 在主线程同步派发。
/// 订阅者返回一个 token,用其取消订阅。所有事件携带 `Sendable` 快照,不持有 @Model。
enum PlaybackEvent: Sendable {
    case trackStarted(TrackSnapshot)
    case trackPaused(TrackSnapshot)
    case trackResumed(TrackSnapshot)
    case trackSeeked(trackId: UUID, toMs: Double)
    /// 自然播完(引擎完成回调)。`listenedMs` 为实际收听毫秒。
    case trackCompleted(TrackSnapshot, listenedMs: Double)
    /// 用户主动跳过(下一首/上一首且未达完成阈值)。Phase 17 由 History 判定并发出。
    case trackSkipped(TrackSnapshot, listenedMs: Double)
    /// 停止(暂停后切换到另一曲目 / 退出时仍在播放)。
    case trackStopped(TrackSnapshot, listenedMs: Double)
    case queueChanged
    case playbackSourceChanged(source: TrackSource)
    case outputDeviceChanged
    case focusSessionStarted
    case focusSessionEnded
}

@Observable
@MainActor
final class PlaybackEventBus {
    private var listeners: [UUID: (PlaybackEvent) -> Void] = [:]

    /// 注册监听,返回 token;用 `unsubscribe(_:)` 取消。
    @discardableResult
    func subscribe(_ handler: @escaping (PlaybackEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    /// 在主线程同步派发事件给所有订阅者。
    func post(_ event: PlaybackEvent) {
        for handler in listeners.values {
            handler(event)
        }
    }
}