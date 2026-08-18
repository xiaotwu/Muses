import Foundation

/// 收听上下文快照(Final Spec §10.2 Feature 2 — Contextual Listening)。
///
/// 在播放生命周期转换点(TrackStarted/Completed/Skipped)由 `ContextService` 捕获,
/// 编码为 JSON 存入 `ListeningEvent.contextSummaryJSON`,供历史画像聚合。
///
/// **隐私(Final Spec §15 高风险):**
/// - 仅记录本地时间(hour/dayOfWeek/isWeekend)、可选前台应用 bundle id、输出设备名、耳机启发式。
/// - **绝不**记录窗口标题、URL、文档、按键、剪贴板、屏幕、文件内容。
/// - 前台应用 bundle id 仅在 `PrefKey.contextTrackActiveApp` 显式开启时记录;
///   整个上下文捕获受 `PrefKey.ffContext` 开关控制(默认关 → `capture()` 返回 nil)。
struct ListeningContext: Codable, Sendable, Equatable {
    /// 本地小时(0-23)。
    let hour: Int
    /// 星期(1=周日 … 7=周六,Calendar 当前)。
    let dayOfWeek: Int
    let isWeekend: Bool
    /// 前台应用 bundle id;仅 `contextTrackActiveApp` 开启时非 nil。
    let frontmostAppBundleId: String?
    /// 当前输出设备名(Core Audio best-effort;不可得则 nil,绝不伪造)。
    let outputDeviceName: String?
    /// 耳机启发式(基于设备名含 headphone/airpod/earphone/beats);不可得则 nil。
    let isHeadphones: Bool?

    /// 画像时段分类,供 HistoryService 聚合。
    enum TimeBand: String, Codable, Sendable {
        case morning      // 5..<12
        case afternoon    // 12..<18
        case evening      // 18..<22
        case lateNight    // 0..<5 或 22..<24
    }

    var timeBand: TimeBand {
        switch hour {
        case 5..<12:  return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default:      return .lateNight   // 0..<5 与 22..<24
        }
    }
}

/// 上下文画像聚合结果(Final Spec §10.2:most-played-while-app / late-night / morning /
/// headphone / weekend)。不可变值,供 UI 展示。
struct ListeningContextProfile: Sendable, Identifiable {
    let id: String          // 画像稳定标识(如 "app:com.apple.Xcode" / "band:lateNight")
    let label: String       // 本地化展示名
    let playCount: Int
    /// 命中事件中的 top 曲目(按播放数倒序,截断)。
    let topTracks: [ContextProfileTrack]

    struct ContextProfileTrack: Sendable, Identifiable {
        let id: UUID
        let title: String
        let artist: String
        let plays: Int
    }
}