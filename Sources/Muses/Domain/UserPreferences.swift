import Foundation
import SwiftUI

/// The two display modes of the Now Playing page.
enum NowPlayingMode: String, CaseIterable, Codable {
    case cover   // Large cover art
    case vinyl   // Spinning vinyl
}

/// Now Playing lyrics presentation: inline = in the right column; lyricsOnly = full-screen lyrics; minimal = one line.
enum NowPlayingLyricsMode: String, CaseIterable, Codable {
    case inline      // Inline in the right column (default, existing layout)
    case lyricsOnly  // Full-screen lyrics (cover/controls give way to centered large-type lyrics)
    case minimal     // Minimal single line (only the current line, centered, extra large)

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

/// App theme. `system` follows the system appearance; `dark`/`light` override it.
enum AppTheme: String, CaseIterable, Codable {
    case dark, light, system

    /// Maps to SwiftUI `preferredColorScheme`. `.system` returns nil (follow the system).
    var effectiveColorScheme: ColorScheme? {
        switch self {
        case .dark:  return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// App language. `system` follows the system language; `en`/`zh` override it.
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

/// yt-dlp cookie source (@AppStorage string).
enum YTCookieSource: String, CaseIterable, Codable {
    case none      // No cookie
    case safari
    case chrome
    case firefox
    case file      // Custom cookie file path

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

/// Centralized @AppStorage key constants.
enum PrefKey {
    static let nowPlayingMode = "muses.nowPlayingMode"
    /// Now Playing lyrics presentation: inline/lyricsOnly/minimal.
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
    /// Disclosure toggle for YouTube technical details, shown to advanced users; everyone else sees only one-click connect.
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
    // MARK: - Feature flags (product upgrade switches; default false = existing behavior, opt in per feature)
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
    /// Optional local-music hardening: after a move/rename, re-associate the Track row using a content fingerprint of the first 64KB.
    static let ffLocalHardening     = "muses.ff.localHardening"
    /// Dynamic Home discovery: Home's remote discovery sections come from a provider, cache-first with per-section failure.
    static let ffDiscovery          = "muses.ff.discovery"
    /// Situational recommendations on the New tab: deterministic scoring based on History/Context/Sessions/Focus.
    static let ffSituationalNew     = "muses.ff.situationalNew"
    /// Global hotkey bindings (JSON-encoded [action: HotkeyShortcut]).
    static let globalHotkeys        = "muses.globalHotkeys.bindings"
    /// Audio output: preferred device name (Audio Nerd Mode).
    static let audioPreferredOutputDevice = "muses.audio.preferredOutputDevice"
    /// Contextual listening: record the frontmost app bundle id (privacy-sensitive, off by default).
    static let contextTrackActiveApp = "muses.context.trackActiveApp"
}

/// In-app feature flags enabled by default (the user opted into "enable all").
/// Global hotkeys / mini player / desktop lyrics stay off by default — they consume
/// system resources and can be intrusive.
/// The menu bar icon is on by default, replacing the system note icon with a template-style App icon.
/// This list feeds `UserDefaults.register(defaults:)`; it only registers keys the user has not
/// explicitly set, so it never reverts a feature the user manually turned off.
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
