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
         pollProvider: @escaping () -> Bool = { true }) {
        self.eventBus = eventBus
        self.enabledProvider = enabledProvider
        self.pollProvider = pollProvider
    }

    /// Refreshes the device list and default id. Called at launch and when toggling the setting.
    func refresh() {
        devices = Self.enumerate()
        defaultDeviceID = Self.defaultDeviceID()
        restorePreferredDevice()
        revision &+= 1
    }

    /// Starts the lightweight 2s poll that detects default-device changes and posts the event. Idempotent.
    func startPolling() {
        guard pollTask == nil, isEnabled, pollProvider() else { return }
        refresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                let cur = Self.defaultDeviceID()
                if cur != self.lastObservedDefault {
                    self.lastObservedDefault = cur
                    self.defaultDeviceID = cur
                    self.devices = Self.enumerate()
                    self.revision &+= 1
                    self.eventBus?.post(.outputDeviceChanged)
                }
            }
        }
    }

    /// Switches the system default output device (best-effort). Returns the OSStatus on failure; never fabricates success.
    @discardableResult
    func setDefault(_ id: UInt32) -> OSStatus {
        var dev = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &dev) { ptr in
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                        UInt32(MemoryLayout<UInt32>.size), ptr)
        }
        if status == noErr {
            UserDefaults.standard.set(name(for: id), forKey: PrefKey.audioPreferredOutputDevice)
            defaultDeviceID = id
            revision &+= 1
        }
        return status
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
        ids = [AudioDeviceID](unsafeUninitializedCapacity: count) { buf, initialized in
            status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                  0, nil, &size, buf.baseAddress!)
            initialized = status == noErr ? count : 0
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id -> AudioDevice? in
            guard let name = propertyName(id) else { return nil }
            let ch = outputChannels(id)
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
        return status == noErr ? UInt32(id) : nil
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
        var channels = 0
        let nBuffers = Int(abl.pointee.mNumberBuffers)
        let buffers = withUnsafePointer(to: &abl.pointee.mBuffers) { ptr in
            ptr.withMemoryRebound(to: AudioBuffer.self, capacity: nBuffers) { $0 }
        }
        for i in 0..<nBuffers {
            channels += Int(buffers[i].mNumberChannels)
        }
        return channels
    }
}