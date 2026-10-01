import AppKit
import CoreGraphics
import Observation

/// Owns only transport media keys while Muses has an audio item to control.
/// Filtering both edges prevents the system from launching another player.
@MainActor
@Observable
final class MediaKeyMonitor {
    @ObservationIgnored nonisolated(unsafe) private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private let canHandle: () -> Bool
    @ObservationIgnored private let dispatch: (String) -> Void
    private(set) var handledPressCount = 0
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(canHandle: @escaping () -> Bool, dispatch: @escaping (String) -> Void) {
        self.canHandle = canHandle
        self.dispatch = dispatch
    }

    func start() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let handled = MainActor.assumeIsolated {
                    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return false
                    }
                    guard monitor.canHandle(), let native = NSEvent(cgEvent: event),
                          native.type == .systemDefined, native.subtype.rawValue == 8,
                          let action = MediaKeyPolicy.action(data1: native.data1) else {
                        return false
                    }
                    if MediaKeyPolicy.isInitialPress(data1: native.data1) {
                        // Leave the synchronous event callback before invoking playback.
                        Task { @MainActor [weak monitor] in
                            guard let monitor, monitor.canHandle() else { return }
                            monitor.handledPressCount += 1
                            monitor.dispatch(action)
                        }
                    }
                    return true
                }
                return handled ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
    }
}

@MainActor
enum MediaKeyPolicy {
    static func action(data1: Int) -> String? {
        switch (data1 >> 16) & 0xffff {
        case 16: CommandRegistry.togglePlayback
        case 17: CommandRegistry.next
        case 18: CommandRegistry.previous
        default: nil
        }
    }

    static func isInitialPress(data1: Int) -> Bool {
        ((data1 >> 8) & 0xff) == 0x0a && (data1 & 1) == 0
    }
}
