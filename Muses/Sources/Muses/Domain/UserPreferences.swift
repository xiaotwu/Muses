import Foundation
import SwiftUI

/// Now Playing 页面的两种展示模式。
enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // 巨大封面
    case vinyl   // 唱片旋转
}

/// Now Playing 歌词呈现模式(Phase 22 §10.8):inline=右栏内联;lyricsOnly=全屏歌词;minimal=单行。
enum NowPlayingLyricsMode: String, CaseIterable, Codable {
    case inline      // 右栏内联(默认,既有布局)
    case lyricsOnly  // 全屏歌词(封面/控件让位,歌词居中大字)
    case minimal     // 极简单行(仅当前一行,居中超大)

    var next: NowPlayingLyricsMode {
        switch self {
        case .inline:     return .lyricsOnly
        case .lyricsOnly: return .minimal
        case .minimal:    return .inline
        }
    }

    var iconName: String {
        switch self {
        case .inline:     return "text.alignleft"
        case .lyricsOnly: return "rectangle.expand.vertical"
        case .minimal:    return "textformat.size.smaller"
        }
    }
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

/// 应用语言。`system` 跟随系统语言;`en`/`zh` 强制覆盖。
enum AppLanguage: String, CaseIterable, Codable {
    case system, en, zh

    var displayName: String {
        switch self {
        case .system: return tr("System", "跟随系统")
        case .en:     return "English"
        case .zh:     return "简体中文"
        }
    }
}

/// yt-dlp cookie 来源(@AppStorage 字符串)。
enum YTCookieSource: String, CaseIterable, Codable {
    case none      // 不使用 cookie
    case safari
    case chrome
    case firefox
    case file      // 自定义 cookie 文件路径

    var displayName: String {
        switch self {
        case .none:    return tr("None", "不使用")
        case .safari:  return "Safari"
        case .chrome:  return "Chrome"
        case .firefox: return "Firefox"
        case .file:    return tr("Cookie File", "Cookie 文件")
        }
    }

    static var settingsCases: [YTCookieSource] { allCases }

    /// Kept as a no-op so older tests/callers compile. Chrome cookies are supported.
    static func migrateChromeIfNeeded(defaults: UserDefaults = .standard) {}
}

/// @AppStorage 键常量集中管理。
enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    /// Now Playing 歌词呈现模式(Phase 22):inline/lyricsOnly/minimal。
    static let nowPlayingLyricsMode = "muses.nowPlaying.lyricsMode"
    static let theme = "muses.theme"
    static let eqActivePresetId = "muses.eq.activePresetId"
    static let lyricsSource = "muses.lyrics.source"
    static let audioQuality = "muses.audio.quality"
    static let checkForUpdates = "muses.updates.checkAutomatically"
    static let lastUpdateCheckAt = "muses.updates.lastCheckAt"
    static let latestKnownVersion = "muses.updates.latestVersion"
    static let ytCookieSource = "muses.yt.cookieSource"
    static let ytCookiePath = "muses.yt.cookiePath"
    /// Isolated YouTube Music Web Home. This is deliberately independent of
    /// playback's yt-dlp cookie preference and defaults to disabled.
    static let webHomeEnabled = "muses.webHome.enabled"
    /// Version of the explicit disclosure accepted by the user. Zero means
    /// no current consent; no cookie access is allowed in that state.
    static let webHomeConsentVersion = "muses.webHome.consentVersion"
    /// Records the narrow decision to use the supported default-browser source
    /// shown in the dedicated Web Home disclosure. It never stores cookie
    /// contents, authentication headers, or browser profile paths.
    static let webHomeDefaultBrowserConsent = "muses.webHome.defaultBrowserConsent"
    /// Safari/Chrome/Firefox source bound at confirmation time. This remains
    /// independent of playback's yt-dlp cookie source.
    static let webHomeBrowserSource = "muses.webHome.browserSource"
    /// 资深用户可见的 YouTube 技术细节折叠开关;普通用户只看到一键连接。
    static let ytShowAdvanced = "muses.yt.showAdvanced"
    static let notificationsTrackChange = "muses.notifications.trackChange"
    static let crossfadeSeconds = "muses.playback.crossfadeSeconds"
    static let replayGainEnabled = "muses.playback.replayGainEnabled"
    static let volume = "muses.playback.volume"
    static let gpuAcceleration = "muses.gpuAcceleration"
    static let language = "muses.language"
    static let ytAudioQuality = "muses.yt.quality"
    /// IFrame suggested video quality: auto / hd1080 / hd720 / large / medium.
    static let ytVideoQuality = "muses.yt.videoQuality"
    static let hoverPreviewSound = "muses.ui.hoverPreviewSound"
    static let sidebarPlaylistOrder = "muses.ui.sidebarPlaylistOrder"
    /// Resume the audio queue after the YouTube video overlay is closed.
    static let resumeAfterVideo = "muses.playback.resumeAfterVideo"
    // MARK: - Feature flags (Phase 16+ 产品升级开关;默认 false = 现有行为 + 按需开启)
    static let ffSmartHistory       = "muses.ff.smartHistory"
    static let ffSessions           = "muses.ff.sessions"
    static let ffAdvancedQueue      = "muses.ff.advancedQueue"
    static let ffInbox              = "muses.ff.inbox"
    static let ffNotes              = "muses.ff.notes"
    static let ffAdvancedLyrics     = "muses.ff.advancedLyrics"
    static let ffFocusMode          = "muses.ff.focusMode"
    static let ffAudioNerd          = "muses.ff.audioNerd"
    static let ffContext             = "muses.ff.context"
    static let ffAutomation         = "muses.ff.automation"
    static let ffMiniPlayer         = "muses.ff.miniPlayer"
    static let ffTray                = "muses.ff.tray"
    static let ffDesktopLyrics      = "muses.ff.desktopLyrics"
    static let ffGlobalHotkeys      = "muses.ff.globalHotkeys"
    /// 本地音乐硬化(Phase 27,可选):移动/重命名后用前 64KB 内容指纹重新关联 Track 行。
    static let ffLocalHardening     = "muses.ff.localHardening"
    /// Home 动态发现(Phase D3):Home 远程发现区段由 provider 产出,cache-first + per-section failure。
    static let ffDiscovery          = "muses.ff.discovery"
    /// New 情境化推荐(Phase D5):基于 History/Context/Sessions/Focus 的确定性打分。
    static let ffSituationalNew     = "muses.ff.situationalNew"
    /// 全局热键绑定(JSON 编码的 [action: HotkeyShortcut])。
    static let globalHotkeys        = "muses.globalHotkeys.bindings"
    /// 音频输出:优先设备名(Phase 26 Audio Nerd Mode)。
    static let audioPreferredOutputDevice = "muses.audio.preferredOutputDevice"
    /// 上下文监听:记录前台应用 bundle id(隐私敏感,默认关闭)。
    static let contextTrackActiveApp = "muses.context.trackActiveApp"
}

/// P5 issue #7 — 应用内功能标志默认开启清单(用户显式选择「全部启用」)。
/// 全局热键 / 迷你播放器 / 桌面歌词默认关——占用系统资源、不打扰。
/// 菜单栏图标默认开,用模板化 App 图标代替系统音符。
/// 此清单用于 `UserDefaults.register(defaults:)`,仅注册用户未显式设置过的键,
/// 不回退用户曾手动关闭的选择。
enum FeatureFlagDefaults {
    static let enabledByDefault: [String: Bool] = [
        PrefKey.ffSmartHistory: true,
        PrefKey.ffSessions: true,
        PrefKey.ffAdvancedQueue: true,
        PrefKey.ffInbox: true,
        PrefKey.ffNotes: true,
        PrefKey.ffContext: true,
        PrefKey.ffAutomation: true,
        PrefKey.ffAudioNerd: true,
        PrefKey.ffFocusMode: true,
        PrefKey.ffDiscovery: true,
        PrefKey.ffSituationalNew: true,
        PrefKey.ffTray: true
    ]
}

enum WebHomePreferenceDefaults {
    static let consentVersion = 2
    @MainActor
    static let values: [String: Any] = [
        PrefKey.webHomeEnabled: false,
        PrefKey.webHomeConsentVersion: 0,
        PrefKey.webHomeDefaultBrowserConsent: false,
        PrefKey.webHomeBrowserSource: ""
    ]
}
