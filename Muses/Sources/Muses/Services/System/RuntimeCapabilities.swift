import Foundation
import AppKit

/// 运行时能力探测:供各特性按 SUPPORTED / LIMITED / UNSUPPORTED 门控 UI,
/// 而不是假设平台支持。能力一旦确定在进程生命周期内不变,故用 let + 构造期探测。
@Observable
@MainActor
final class RuntimeCapabilities {

    enum Status { case supported, limited, unsupported }

    let globalHotkeys: Status
    let mediaKeys: Status
    let tray: Status
    let miniWindow: Status
    let desktopLyrics: Status
    let activeApplicationDetection: Status
    let outputDeviceEnumeration: Status
    let outputDeviceSwitching: Status
    let headphoneDetection: Status
    let wordSyncedLyrics: Status
    let translationLyrics: Status
    let audioAnalysis: Status
    let weatherContext: Status

    init() {
        // macOS 14+ 原生能力。Carbon RegisterEventHotKey 仍可用;NSStatusItem / NSPanel /
        // NSWorkspace.frontmostApplication / Core Audio 均为系统 API。
        globalHotkeys = .supported
        mediaKeys = .supported
        tray = .supported
        miniWindow = .supported
        desktopLyrics = .supported
        activeApplicationDetection = .supported
        outputDeviceEnumeration = .supported
        // AVAudioEngine 路由到系统默认设备;按设备路由需手动图/AVAudioIONNode,尽力而为。
        outputDeviceSwitching = .limited
        // 无系统 API 直接判定耳机;靠设备名/传输类型启发式,不可靠。
        headphoneDetection = .limited
        // 无免费 word-sync/翻译歌词提供商;结构支持,数据回退 line→plain。
        wordSyncedLyrics = .limited
        translationLyrics = .limited
        audioAnalysis = .supported
        // 天气上下文需网络+定位,超出本地优先音乐 app 范围,本期不实现。
        weatherContext = .unsupported
    }

    /// 便利:把 Status 映射为布尔"是否可用"(limited 也算可用,UI 需另行说明限制)。
    func isUsable(_ s: Status) -> Bool { s != .unsupported }

    /// 用户可读的本地化说明(给禁用态 UI 用)。
    func explanation(for s: Status) -> String {
        switch s {
        case .supported:  return tr("Supported", "支持")
        case .limited:    return tr("Supported with limitations", "受限支持")
        case .unsupported: return tr("Not supported on this platform", "此平台不支持")
        }
    }
}
