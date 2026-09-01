import Foundation
import CoreAudio
import Observation

/// 音频输出设备服务(Final Spec §10.10 Feature 10 — Audio Nerd Mode)。
///
/// 枚举 Core Audio 输出设备、读取/切换系统默认输出(best-effort)、检测默认变更。
/// **绝不伪造**:任一 Core Audio 调用失败即返回空/nil,UI 显示「Unknown」。
/// 优先设备记忆到 `UserDefaults`(`PrefKey.audioPreferredOutputDevice`,设备名而非 id,
/// 因 id 跨重启不稳定)。变更检测用 2s 轻量轮询(低频,避免高频状态),发 `.outputDeviceChanged`。
@Observable
@MainActor
final class AudioDeviceService {
    struct AudioDevice: Sendable, Identifiable, Equatable {
        let id: UInt32      // AudioDeviceID
        let name: String
        let channels: Int   // 输出声道数(best-effort)
    }

    private let eventBus: PlaybackEventBus?
    private let enabledProvider: () -> Bool
    private let pollProvider: () -> Bool
    private var pollTask: Task<Void, Never>?
    private(set) var revision: Int = 0

    /// 当前可用设备(最近一次枚举)。
    private(set) var devices: [AudioDevice] = []
    /// 当前系统默认输出设备 id(nil = 不可得)。
    private(set) var defaultDeviceID: UInt32?
    /// 上次观察到的默认 id(用于变更检测)。
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

    /// 刷新设备列表 + 默认 id。启动时与设置切换时调用。
    func refresh() {
        devices = Self.enumerate()
        defaultDeviceID = Self.defaultDeviceID()
        restorePreferredDevice()
        revision &+= 1
    }

    /// 启动 2s 轻量轮询,检测默认设备变更并发事件。幂等。
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

    /// 切换系统默认输出设备(best-effort)。失败返回 OSStatus,绝不伪造成功。
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

    /// 记忆的优先设备名(nil = 未设)。
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

    // MARK: - Core Audio(静态 best-effort)

    /// 枚举所有设备 + 输出声道数。任一步失败 → 该设备项以 best-effort 占位或跳过;整体失败返回空。
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