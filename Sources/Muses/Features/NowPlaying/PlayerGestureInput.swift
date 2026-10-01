import AppKit
import SwiftUI

struct PlayerGestureTailState {
    private var startedAt: TimeInterval?
    private var lastEventAt: TimeInterval = 0

    mutating func begin(at timestamp: TimeInterval) {
        startedAt = timestamp
        lastEventAt = timestamp
    }

    func isExpired(at timestamp: TimeInterval) -> Bool {
        startedAt == nil || timestamp - lastEventAt > 0.3
    }

    mutating func consume(at timestamp: TimeInterval, newGesture: Bool, precise: Bool) -> Bool {
        guard let startedAt else { return false }
        if isExpired(at: timestamp) || (newGesture && timestamp > startedAt) {
            self.startedAt = nil
            return false
        }
        guard precise else { return false }
        lastEventAt = timestamp
        return true
    }
}

/// Outlives the dismissed overlay so its remaining finger and momentum events
/// cannot scroll the browsing surface revealed beneath it.
@MainActor
final class PlayerGestureTail {
    static let shared = PlayerGestureTail()
    private weak var window: NSWindow?
    private var state = PlayerGestureTailState()
    private var monitor: Any?
    private var cleanup: Task<Void, Never>?

    func begin(_ event: NSEvent) {
        stop()
        window = event.window
        state.begin(at: event.timestamp)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) == true }
            return consumed ? nil : event
        }
        cleanup = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                if state.isExpired(at: ProcessInfo.processInfo.systemUptime) {
                    stop()
                    return
                }
            }
        }
    }

    func consume(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        return state.consume(at: event.timestamp, newGesture: event.phase.contains(.began),
                             precise: event.hasPreciseScrollingDeltas)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cleanup?.cancel()
        cleanup = nil
        window = nil
        state = PlayerGestureTailState()
    }
}

struct PlayerGesturePolicy {
    enum Action: Equatable { case close, next, previous, lyrics }
    /// Scroll deltas are already adjusted by the system preference. Restore
    /// physical finger motion so down/left mean the same with natural scrolling off.
    static func fingerDelta(_ delta: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        delta * (invertedFromDevice ? 1 : -1)
    }

    static func action(x: CGFloat, y: CGFloat, close: Bool, tracks: Bool, lyrics: Bool) -> Action? {
        guard max(abs(x), abs(y)) >= 65 else { return nil }
        if abs(y) > abs(x) * 1.5 {
            if y > 0 && close { return .close }
            if y < 0 && lyrics { return .lyrics }
        } else if abs(x) > abs(y) * 1.5, tracks {
            return x < 0 ? .next : .previous
        }
        return nil
    }
}

/// Precise scroll phases identify trackpad swipes. One action per gesture;
/// inertial events and native scrolling/control regions never drive playback.
struct PlayerGestureInput: NSViewRepresentable {
    var enabled: Bool
    var close: Bool
    var tracks: Bool
    var lyrics: Bool
    var hasLyricsColumn: Bool
    var perform: (PlayerGesturePolicy.Action) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.configuration = self
        context.coordinator.install()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.configuration = self }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var configuration: PlayerGestureInput?
        var monitor: Any?
        var x: CGFloat = 0
        var y: CGFloat = 0
        var triggered = false
        var eligible = false

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let config = configuration, config.enabled,
                  event.window === view.window, event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.began) {
                x = 0; y = 0; triggered = false
                let point = view.convert(event.locationInWindow, from: nil)
                eligible = view.bounds.contains(point)
                    && (!config.hasLyricsColumn || point.x < view.bounds.width * 0.5)
                var hit = event.window?.contentView?.hitTest(event.locationInWindow)
                while let target = hit {
                    if target is NSScrollView || target is NSControl { eligible = false; break }
                    hit = target.superview
                }
            }
            guard eligible, !triggered else { return event }
            guard event.phase.contains(.began) || event.phase.contains(.changed) else { return event }
            x += PlayerGesturePolicy.fingerDelta(event.scrollingDeltaX, invertedFromDevice: event.isDirectionInvertedFromDevice)
            y += PlayerGesturePolicy.fingerDelta(event.scrollingDeltaY, invertedFromDevice: event.isDirectionInvertedFromDevice)
            if let action = PlayerGesturePolicy.action(x: x, y: y, close: config.close, tracks: config.tracks, lyrics: config.lyrics) {
                triggered = true
                if action == .close { PlayerGestureTail.shared.begin(event) }
                config.perform(action)
                return nil
            }
            return event
        }
    }
}
