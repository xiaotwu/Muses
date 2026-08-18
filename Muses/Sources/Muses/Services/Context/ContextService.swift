import Foundation
import AppKit
import CoreAudio
import Observation

/// 上下文捕获服务(Final Spec §10.2 Feature 2 — Contextual Listening)。
///
/// 在播放转换点提供当前 `ListeningContext` 快照(供 `HistoryService` 编码到
/// `ListeningEvent.contextSummaryJSON`)。**隐私优先**:整体受 `PrefKey.ffContext` 控制
/// (默认关 → `capture()` 返回 nil);前台应用 bundle id 仅在 `PrefKey.contextTrackActiveApp`
/// 显式开启时记录;绝不读取窗口标题/URL/文档/按键/剪贴板/屏幕/文件内容。
///
/// 可注入性:`frontmostAppProvider`/`deviceProvider`/`nowProvider` 默认走系统 API,
/// 测试可注入固定值以避免 AppKit/Core Audio 依赖。输出设备名 + 耳机启发式为 best-effort,
/// 任何环节不可得即 nil,绝不伪造(Final Spec §15)。
@Observable
@MainActor
final class ContextService {
    private let trackActiveAppProvider: () -> Bool
    private let frontmostAppProvider: () -> String?
    private let deviceProvider: () -> DeviceContext
    private let nowProvider: () -> Date
    private let enabledProvider: () -> Bool
    private let calendar: Calendar

    /// 设备上下文(best-effort)。`revision` 供 UI 观察设备变化刷新。
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

    /// 捕获当前上下文。`ffContext` 关闭返回 nil(隐私默认关,不落库)。
    func capture() -> ListeningContext? {
        guard isEnabled else { return nil }
        let now = nowProvider()
        let hour = calendar.component(.hour, from: now)
        let dow = calendar.component(.weekday, from: now)   // 1=周日
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

    /// 供 `HistoryService` 编码上下文到 `contextSummaryJSON`。
    static func encode(_ context: ListeningContext?) -> String? {
        guard let context else { return nil }
        let data = try? JSONEncoder().encode(context)
        return data.map { String(data: $0, encoding: .utf8) } ?? nil
    }

    /// 供 `HistoryService`/画像聚合解码 `contextSummaryJSON`。
    static func decode(_ json: String?) -> ListeningContext? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ListeningContext.self, from: data)
    }

    // MARK: - Core Audio 设备(best-effort)

    /// 读取系统默认输出设备名 + 耳机启发式。任一步失败返回 nil 字段,绝不伪造。
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