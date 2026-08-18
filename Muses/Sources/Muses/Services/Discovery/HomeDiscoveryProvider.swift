import Foundation

/// Home 发现输入:携带供给 provider 生成区段所需的轻量信号(§3)。
///
/// 全部为 `Sendable` 值,可安全跨 actor。输入仅含**轻度**历史排序信号
/// (top/最近/收藏艺术家名);强个性化在 New(Phase D5)。
struct HomeDiscoveryInput: Sendable, Equatable {
    /// 用户最常听的艺术家名(按播放数倒序,最多 5 个)。
    let topArtistNames: [String]
    /// 最近播放中出现的艺术家名(去重,最多 5 个)。
    let recentlyPlayedArtistNames: [String]
    /// 收藏曲目的艺术家名(去重,最多 5 个)。
    let likedArtistNames: [String]
    /// 当前本地时段(用于时段主题区段,如 morning/lateNight)。
    let timeBand: ListeningContext.TimeBand
    /// 当前小时(0-23),供 provider 细分主题。
    let hour: Int

    static func == (lhs: HomeDiscoveryInput, rhs: HomeDiscoveryInput) -> Bool {
        lhs.topArtistNames == rhs.topArtistNames
            && lhs.recentlyPlayedArtistNames == rhs.recentlyPlayedArtistNames
            && lhs.likedArtistNames == rhs.likedArtistNames
            && lhs.timeBand == rhs.timeBand
            && lhs.hour == rhs.hour
    }
}

/// Home 发现提供者协议(§3)。
///
/// 抽象出"外部 YouTube/音乐世界发现"来源,使未来接入真实鉴权的 YouTube Music
/// Home provider 时无需改动 Home UI。本阶段默认实现 `YTDlpDiscoveryProvider` 基于
/// yt-dlp `ytsearch` 的主题化搜索;**不**实现脆弱的内部 API。
///
/// 实现要点:
/// - 区段标题由 provider 根据 `input` 生成(不硬编码在视图)。
/// - 每个 section 独立产出,单 section 失败返回 `.failed` 不影响其它 section。
/// - 历史仅作轻度排序(结果按与 top artists 的重叠度重排)。
@MainActor
protocol HomeDiscoveryProvider: AnyObject {
    func sections(for input: HomeDiscoveryInput) async -> [HomeSection]
}