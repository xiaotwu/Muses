import Foundation
import SwiftUI

/// Now Playing 页面的两种展示模式。
enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // 巨大封面
    case vinyl   // 唱片旋转
}

/// 应用主题。`system` 跟随系统外观;`dark`/`light` 强制覆盖。
enum AppTheme: String, CaseIterable, Codable {
    case dark, light, system

    /// 映射到 SwiftUI `preferredColorScheme`。`.system` 返回 nil(跟随系统)。
    var effectiveColorScheme: ColorScheme? {
        switch self {
        case .dark:  return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// @AppStorage 键常量集中管理。
enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    static let theme = "muses.theme"
    static let eqActivePresetId = "muses.eq.activePresetId"
    static let lyricsSource = "muses.lyrics.source"
    static let audioQuality = "muses.audio.quality"
    static let checkForUpdates = "muses.updates.checkAutomatically"
}