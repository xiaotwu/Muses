import Foundation
import CoreAudio
import Observation

/// Audio output device service (Final Spec §10.10 Feature 10 — Audio Nerd Mode).
///
/// Enumerates Core Audio output devices, reads/switches the system default output (best-effort),
/// and detects default-device changes. **Never fabricates data**: any failed Core Audio call
/// returns empty/nil, and the UI then shows "Unknown". The preferred device is remembered in
/// `UserDefaults` (`PrefKey.audioPreferredOutputDevice`, stored by device name rather than id,
/// since ids are not stable across reboots). Change detection uses a lightweight 2s poll
/// (kept low-frequency to avoid high-rate state churn) and posts `.outputDeviceChanged`.
@Observable
@MainActor
final class AudioDeviceService {
    struct AudioDevice: Sendable, Identifiable, Equatable {
        let id: UInt32      // AudioDeviceID
        let name: String
        let channels: Int   // output channel count (best-effort)
    }

    private let eventBus: PlaybackEventBus?
    private let enabledProvider: () -> Bool
    private let pollProvider: () -> Bool
    private let enumerateDevices: () -> [AudioDevice]
    private let readDefault: () -> UInt32?
    private let writeDefault: (UInt32) -> OSStatus
    private let onUnexpectedDisconnect: () -> Void
    private(set) var lastError: OSStatus?
    private var pollTask: Task<Void, Never>?
    private(set) var revision: Int = 0

    /// Currently available devices (from the most recent enumeration).
    private(set) var devices: [AudioDevice] = []
    /// Current system default output device id (nil = unavailable).
    private(set) var defaultDeviceID: UInt32?
    /// Last observed default id (used for change detection).
    private var lastObservedDefault: UInt32?

    var isEnabled: Bool { enabledProvider() }

    init(eventBus: PlaybackEventBus? = nil,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffAudioNerd)
    },
         pollProvider: @escaping () -> Bool = { true },
         enumerateDevices: @escaping () -> [AudioDevice] = { AudioDeviceService.enumerate() },
         readDefault: @escaping () -> UInt32? = { AudioDeviceService.defaultDeviceID() },
         writeDefault: @escaping (UInt32) -> OSStatus = { AudioDeviceService.writeSystemDefault($0) },
         onUnexpectedDisconnect: @escaping () -> Void = {}) {
        self.onUnexpectedDisconnect = onUnexpectedDisconnect
        self.enumerateDevices = enumerateDevices
        self.readDefault = readDefault
        self.writeDefault = writeDefault
        self.eventBus = eventBus
        self.enabledProvider = enabledProvider
        self.pollProvider = pollProvider
    }

    /// Refreshes the device list and default id. Called at launch and when toggling the setting.
    func refresh() {
        devices = enumerateDevices().filter { $0.channels > 0 }
        defaultDeviceID = readDefault()
        lastObservedDefault = defaultDeviceID
        lastError = devices.isEmpty || defaultDeviceID == nil ? kAudioHardwareBadDeviceError : nil
        revision &+= 1
    }

    /// Starts the lightweight 2s poll that detects default-device changes and posts the event. Idempotent.
    func startPolling() {
        guard pollTask == nil, pollProvider() else { return }
        refresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.pollOutputChange()
            }
        }
    }

    /// A removed output pauses playback. Switching between available outputs
    /// or reconnecting only updates device state and never grants play intent.
    func pollOutputChange() {
        let current = readDefault()
        guard current != lastObservedDefault else { return }
        let previous = lastObservedDefault
        let available = enumerateDevices().filter { $0.channels > 0 }
        lastObservedDefault = current
        defaultDeviceID = current
        devices = available
        lastError = available.isEmpty || current == nil ? kAudioHardwareBadDeviceError : nil
        revision &+= 1
        if let previous, current == nil || !available.contains(where: { $0.id == previous }) {
            onUnexpectedDisconnect()
        }
        eventBus?.post(.outputDeviceChanged)
    }

    /// Switches the system default output device (best-effort). Returns the OSStatus on failure; never fabricates success.
    @discardableResult
    func setDefault(_ id: UInt32) -> OSStatus {
        guard devices.contains(where: { $0.id == id && $0.channels > 0 }) else {
            lastError = kAudioHardwareBadDeviceError
            return kAudioHardwareBadDeviceError
        }
        let status = writeDefault(id)
        guard status == noErr else { lastError = status; return status }
        guard readDefault() == id else {
            lastError = kAudioHardwareUnspecifiedError
            return kAudioHardwareUnspecifiedError
        }
        lastError = nil
        UserDefaults.standard.set(name(for: id), forKey: PrefKey.audioPreferredOutputDevice)
        defaultDeviceID = id
        lastObservedDefault = id
        revision &+= 1
        eventBus?.post(.outputDeviceChanged)
        return noErr
    }

    static func writeSystemDefault(_ id: UInt32) -> OSStatus {
        var device = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &device)
    }

    /// Remembered preferred device name (nil = not set).
    var preferredDeviceName: String? {
        let v = UserDefaults.standard.string(forKey: PrefKey.audioPreferredOutputDevice)
        return v?.isEmpty == false ? v : nil
    }

    /// Apply the remembered output device if it is still connected.
    @discardableResult
    func restorePreferredDevice() -> Bool {
        guard let name = preferredDeviceName,
              let match = devices.first(where: { $0.name == name }) else { return false }
        if match.id == defaultDeviceID { return true }
        return setDefault(match.id) == noErr
    }

    private func name(for id: UInt32) -> String? {
        devices.first { $0.id == id }?.name
    }

    // MARK: - Core Audio (static best-effort helpers)

    /// Enumerates all devices plus their output channel counts. A per-device failure yields a best-effort placeholder or skips the device; a total failure returns empty.
    static func enumerate() -> [AudioDevice] {
        var ids: [AudioDeviceID] = []
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                     0, nil, &size)
        guard status == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        ids = [AudioDeviceID](unsafeUninitializedCapacity: count) { buf, initialized in
            status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                  0, nil, &size, buf.baseAddress!)
            initialized = status == noErr ? count : 0
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id -> AudioDevice? in
            guard let name = propertyName(id) else { return nil }
            let ch = outputChannels(id)
            guard ch > 0 else { return nil }
            return AudioDevice(id: UInt32(id), name: name, channels: ch)
        }
    }

    static func defaultDeviceID() -> UInt32? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &id) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, ptr)
        }
        return status == noErr && id != 0 ? UInt32(id) : nil
    }

    private static func propertyName(_ id: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(id), &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? name as String : nil
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyDataSize(AudioDeviceID(id), &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }
        let listSize = Int(size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let status2 = AudioObjectGetPropertyData(AudioDeviceID(id), &addr, 0, nil, &size, raw)
        guard status2 == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
