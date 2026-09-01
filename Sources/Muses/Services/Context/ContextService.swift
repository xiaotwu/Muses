import Foundation
import AppKit
import CoreAudio
import Observation

/// Context capture service (Final Spec §10.2 Feature 2 — Contextual Listening).
///
/// Provides a snapshot of the current `ListeningContext` at playback transitions
/// (for `HistoryService` to encode into `ListeningEvent.contextSummaryJSON`).
/// **Privacy first**: the whole service is gated by `PrefKey.ffContext`
/// (off by default → `capture()` returns nil); the frontmost app's bundle id is recorded
/// only when `PrefKey.contextTrackActiveApp` is explicitly enabled; window titles/URLs/
/// documents/keystrokes/clipboard/screen/file contents are never read.
///
/// Injectability: `frontmostAppProvider`/`deviceProvider`/`nowProvider` default to system APIs;
/// tests can inject fixed values to avoid AppKit/Core Audio dependencies. Output device name
/// and the headphones heuristic are best-effort — any unavailable step yields nil,
/// never fabricated data (Final Spec §15).
@Observable
@MainActor
final class ContextService {
    private let trackActiveAppProvider: () -> Bool
    private let frontmostAppProvider: () -> String?
    private let deviceProvider: () -> DeviceContext
    private let nowProvider: () -> Date
    private let enabledProvider: () -> Bool
    private let calendar: Calendar

    /// Device context (best-effort). `revision` lets the UI observe device changes and refresh.
    private(set) var revision: Int = 0
    var isEnabled: Bool { enabledProvider() }

    struct DeviceContext: Sendable {
        let outputDeviceName: String?
        let isHeadphones: Bool?
    }

    init(trackActiveAppProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.contextTrackActiveApp)
    },
         frontmostAppProvider: @escaping () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    },
         deviceProvider: @escaping () -> DeviceContext = { ContextService.defaultDevice() },
         nowProvider: @escaping () -> Date = { Date() },
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffContext)
    },
         calendar: Calendar = .current) {
        self.trackActiveAppProvider = trackActiveAppProvider
        self.frontmostAppProvider = frontmostAppProvider
        self.deviceProvider = deviceProvider
        self.nowProvider = nowProvider
        self.enabledProvider = enabledProvider
        self.calendar = calendar
    }

    /// Captures the current context. Returns nil when `ffContext` is off
    /// (privacy defaults to off; nothing is persisted).
    func capture() -> ListeningContext? {
        guard isEnabled else { return nil }
        let now = nowProvider()
        let hour = calendar.component(.hour, from: now)
        let dow = calendar.component(.weekday, from: now)   // 1 = Sunday
        let isWeekend = dow == 1 || dow == 7
        let bundleId = trackActiveAppProvider() ? frontmostAppProvider() : nil
        let dev = deviceProvider()
        return ListeningContext(
            hour: hour, dayOfWeek: dow, isWeekend: isWeekend,
            frontmostAppBundleId: bundleId,
            outputDeviceName: dev.outputDeviceName,
            isHeadphones: dev.isHeadphones
        )
    }

    /// Used by `HistoryService` to encode the context into `contextSummaryJSON`.
    static func encode(_ context: ListeningContext?) -> String? {
        guard let context else { return nil }
        let data = try? JSONEncoder().encode(context)
        return data.map { String(data: $0, encoding: .utf8) } ?? nil
    }

    /// Used by `HistoryService`/profile aggregation to decode `contextSummaryJSON`.
    static func decode(_ json: String?) -> ListeningContext? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ListeningContext.self, from: data)
    }

    // MARK: - Core Audio device (best-effort)

    /// Reads the system default output device name and applies the headphones heuristic.
    /// Any failed step returns nil fields; data is never fabricated.
    static func defaultDevice() -> DeviceContext {
        guard let name = defaultOutputDeviceName() else {
            return DeviceContext(outputDeviceName: nil, isHeadphones: nil)
        }
        let lower = name.lowercased()
        let isHeadphones = lower.contains("headphone") || lower.contains("airpod")
            || lower.contains("earphone") || lower.contains("beats")
            || lower.contains("buds")
        return DeviceContext(outputDeviceName: name, isHeadphones: isHeadphones)
    }

    private static func defaultOutputDeviceName() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &deviceID) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nameStatus == noErr else { return nil }
        return name as String
    }
}