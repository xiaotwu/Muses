import Foundation

/// Sidebar / settings copy for the two YouTube identities:
/// OAuth is the Google account; cookies are only for yt-dlp playback.
enum YouTubeIdentity {
    static func sidebarSubtitle(oauthConnected: Bool,
                                channelTitle: String?,
                                cookieSource: YTCookieSource) -> String {
        if oauthConnected {
            if let title = channelTitle, !title.isEmpty { return title }
            return tr("YouTube account", "YouTube 账号")
        }
        switch cookieSource {
        case .none:
            return tr("Not connected", "未连接")
        case .safari:
            return tr("Safari cookies (playback)", "Safari Cookie（播放）")
        case .chrome:
            return tr("Chrome cookies (playback)", "Chrome Cookie（播放）", zhHant: "Chrome Cookie（播放）")
        case .firefox:
            return tr("Firefox cookies (playback)", "Firefox Cookie（播放）")
        case .file:
            return tr("Cookie file (playback)", "Cookie 文件（播放）")
        }
    }

    /// Cookie status shown on Home discovery failure — not an account login.
    /// Cookie / sign-in / quota failures hit every ytsearch the same way.
    static func isSharedDiscoveryFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("cookie")
            || m.contains("sign in")
            || m.contains("oauth")
            || m.contains("could not find chrome")
            || m.contains("could not find safari")
            || m.contains("could not find firefox")
            || m.contains("http error 403")
            || m.contains("http error 429")
    }

    static func discoveryCookieHint(cookieSource: YTCookieSource) -> String {
        switch cookieSource {
        case .none:
            return tr("No browser cookies. YouTube discovery and some streams need a cookie source in Settings → Account & Content.",
                      "未使用浏览器 Cookie。YouTube 发现和部分播放需要在「设置 → 账号与内容」中选择 Cookie 来源。",
                      zhHant: "未使用瀏覽器 Cookie。YouTube 探索和部分播放需要在「設定 → 帳號與內容」中選擇 Cookie 來源。")
        case .safari:
            return tr("Using Safari cookies. If this keeps failing, refresh Safari’s YouTube login or pick another browser in Settings → Account & Content.",
                      "正在使用 Safari Cookie。若持续失败，请刷新 Safari 的 YouTube 登录，或在「设置 → 账号与内容」改选其他浏览器。",
                      zhHant: "正在使用 Safari Cookie。若持續失敗，請更新 Safari 的 YouTube 登入，或在「設定 → 帳號與內容」改選其他瀏覽器。")
        case .chrome:
            return tr("Using Chrome cookies. If this keeps failing, refresh Chrome’s YouTube login or choose another browser in Account & Content settings.",
                      "正在使用 Chrome Cookie。若持续失败，请刷新 Chrome 的 YouTube 登录，或在「账号与内容」设置中改选浏览器。",
                      zhHant: "正在使用 Chrome Cookie。若持續失敗，請更新 Chrome 的 YouTube 登入，或在「帳號與內容」設定中改選瀏覽器。")
        case .firefox:
            return tr("Using Firefox cookies. If this keeps failing, refresh Firefox’s YouTube login or pick another browser in Settings → Account & Content.",
                      "正在使用 Firefox Cookie。若持续失败，请刷新 Firefox 的 YouTube 登录，或在「设置 → 账号与内容」改选其他浏览器。",
                      zhHant: "正在使用 Firefox Cookie。若持續失敗，請更新 Firefox 的 YouTube 登入，或在「設定 → 帳號與內容」改選其他瀏覽器。")
        case .file:
            return tr("Using a cookie file. If this keeps failing, update the file or pick a browser in Settings → Account & Content.",
                      "正在使用 Cookie 文件。若持续失败，请更新该文件，或在「设置 → 账号与内容」改选浏览器。",
                      zhHant: "正在使用 Cookie 檔案。若持續失敗，請更新該檔案，或在「設定 → 帳號與內容」改選瀏覽器。")
        }
    }
}

/// YouTube Music album playlists use `OLAK5uy_…` / `OLAK…`. Regular `PL…` / `LL…` lists stay playlists.
enum YouTubePlaylistID {
    static func isMusicAlbum(_ playlistId: String) -> Bool {
        playlistId.hasPrefix("OLAK")
    }
}
