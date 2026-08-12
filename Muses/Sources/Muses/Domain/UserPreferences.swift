import Foundation

/// Now Playing 页面的两种展示模式。
enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // 巨大封面
    case vinyl   // 唱片旋转
}

/// 应用主题(阶段 2 仅渲染 dark; light/system 留作阶段 4)。
enum AppTheme: String, CaseIterable, Codable {
    case dark, light, system
}

/// @AppStorage 键常量集中管理。
enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    static let theme = "muses.theme"
    static let eqActivePresetId = "muses.eq.activePresetId"
    static let lyricsSource = "muses.lyrics.source"
    static let audioQuality = "muses.audio.quality"
}