import Foundation

/// Cross-feature playback lifecycle events. Provides a single event source for subscribers
/// such as History / Session / Context / Inbox / Focus, so each feature does not have to
/// poll `PlaybackService.state` on its own.
///
/// Design: a `@MainActor` instance (owned by `PlaybackService`); `post` dispatches
/// synchronously on the main thread. Subscribing returns a token used to unsubscribe.
/// All events carry `Sendable` snapshots and never hold @Model objects.
enum PlaybackEvent: Sendable {
    case trackStarted(TrackSnapshot)
    case trackPaused(TrackSnapshot)
    case trackResumed(TrackSnapshot)
    case trackSeeked(trackId: UUID, toMs: Double)
    /// Natural completion (engine completion callback). `listenedMs` is the actual listened milliseconds.
    case trackCompleted(TrackSnapshot, listenedMs: Double)
    /// User-initiated skip (next/previous without reaching the completion threshold).
    /// Detected and posted by History.
    case trackSkipped(TrackSnapshot, listenedMs: Double)
    /// Stop (switching to another track after pausing / still playing at quit).
    case trackStopped(TrackSnapshot, listenedMs: Double)
    case queueChanged
    case outputDeviceChanged
    case focusSessionStarted
    case focusSessionEnded
}

@Observable
@MainActor
final class PlaybackEventBus {
    private var listeners: [UUID: (PlaybackEvent) -> Void] = [:]

    /// Registers a listener and returns a token; cancel with `unsubscribe(_:)`.
    @discardableResult
    func subscribe(_ handler: @escaping (PlaybackEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    /// Dispatches an event synchronously to all subscribers on the main thread.
    func post(_ event: PlaybackEvent) {
        for handler in listeners.values {
            handler(event)
        }
    }
}
