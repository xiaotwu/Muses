import SwiftUI

/// yt-dlp 桥接器的环境注入键。
private struct YTDlpBridgeEnvironmentKey: EnvironmentKey {
    static let defaultValue: YTDlpBridge? = nil
}

extension EnvironmentValues {
    /// `YTDlpBridge`(由 `MusesApp` 注入);缺省 nil 用于预览/未注入场景。
    var ytDlpBridge: YTDlpBridge? {
        get { self[YTDlpBridgeEnvironmentKey.self] }
        set { self[YTDlpBridgeEnvironmentKey.self] = newValue }
    }
}

/// YouTube / yt-dlp 设置:OAuth 账户连接、二进制路径(只读)、版本检查、cookie 来源。
///
/// P2: 新增 Google OAuth 2.0 账户连接(凭证/令牌存 Keychain,最小只读 scope),
/// 用于 Home 个性化信号;cookie 来源继续服务于 yt-dlp 播放登录态内容。
struct YouTubeSettingsView: View {
    @Environment(\.ytDlpBridge) private var bridge
    // P2 — 真实 Google OAuth 账户(凭证/令牌存 Keychain,最小只读 scope)。
    @Environment(YouTubeAccountService.self) private var account

    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw: String = YTCookieSource.none.rawValue
    @AppStorage(PrefKey.ytCookiePath) private var cookiePath: String = ""

    @State private var binaryPath: String?
    @State private var versionString: String?
    @State private var checkingVersion = false
    @State private var showFilePicker = false
    // OAuth 凭证编辑(本地草稿,保存时写入 Keychain)。
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthRedirectURI = ""
    @State private var oauthSaveError: String?

    private var cookieSource: YTCookieSource {
        YTCookieSource(rawValue: cookieSourceRaw) ?? .none
    }

    /// OAuth 凭证草稿是否可保存(三项非空)。
    private var oauthConfigDraftValid: Bool {
        !oauthClientID.isEmpty && !oauthClientSecret.isEmpty && !oauthRedirectURI.isEmpty
    }

    private var oAuthHelpText: String {
        tr("Create an OAuth 2.0 Client (Desktop type) in Google Cloud Console with the YouTube Data API v3 enabled. Use a custom redirect URI scheme (e.g. muses:/oauth). Credentials and tokens are stored in macOS Keychain; Muses uses the minimum read-only scope and never sends credentials to any server but Google's.",
           "在 Google Cloud Console 创建 OAuth 2.0 桌面客户端并启用 YouTube Data API v3。重定向 URI 用自定义 scheme(如 muses:/oauth)。凭证与令牌存于 macOS 钥匙串;Muses 仅使用最小只读 scope,凭证只发送至 Google。")
    }

    /// 从 Keychain 读取已存凭证填充草稿(便于查看/修改)。
    private func loadOAuthDraft() {
        guard let cfg = account.loadConfig() else { return }
        oauthClientID = cfg.clientID
        oauthClientSecret = cfg.clientSecret
        oauthRedirectURI = cfg.redirectURI
        oauthSaveError = nil
    }

    /// 保存 OAuth 凭证到 Keychain(不在此处发起连接;用户点 Connect…)。
    private func saveOAuthConfig() {
        oauthSaveError = nil
        let cfg = GoogleOAuthConfig(
            clientID: oauthClientID,
            clientSecret: oauthClientSecret,
            redirectURI: oauthRedirectURI,
            scopes: GoogleOAuthConfig.defaultScopes)
        do {
            try account.saveConfig(cfg)
        } catch {
            oauthSaveError = error.localizedDescription
        }
    }

    var body: some View {
        // P2 — YouTube 账户(Google OAuth 2.0 PKCE):用于 Home 个性化信号,
        // 凭证与令牌存 macOS Keychain,最小只读 scope,永不阻断播放。
        Section(tr("YouTube Account (OAuth)", "YouTube 账户(OAuth)")) {
            HStack {
                Text(tr("Status", "状态")).foregroundStyle(BrandColors.textSecondary)
                Spacer()
                if account.isConnecting {
                    ProgressView().controlSize(.small)
                } else if account.isConnected {
                    Label(tr("Connected", "已连接"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(BrandColors.textPrimary)
                        .font(.callout)
                } else {
                    Text(tr("Not connected", "未连接"))
                        .foregroundStyle(BrandColors.textSecondary)
                        .font(.callout)
                }
            }
            if let title = account.account?.channel?.title, !title.isEmpty {
                row(tr("Channel", "频道"), value: title)
            }
            if let err = account.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            TextField(tr("Client ID", "Client ID"), text: $oauthClientID)
                .textFieldStyle(.roundedBorder)
            SecureField(tr("Client Secret", "Client Secret"), text: $oauthClientSecret)
                .textFieldStyle(.roundedBorder)
            TextField(tr("Redirect URI", "重定向 URI"), text: $oauthRedirectURI)
                .textFieldStyle(.roundedBorder)
            if let err = oauthSaveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button {
                    saveOAuthConfig()
                } label: {
                    Label(tr("Save Credentials", "保存凭证"), systemImage: "key.fill")
                }
                .buttonStyle(.bordered)
                .tint(BrandColors.cyan)
                .disabled(!oauthConfigDraftValid)

                if account.isConnected {
                    Button(role: .destructive) {
                        account.disconnect()
                    } label: {
                        Label(tr("Disconnect", "断开连接"), systemImage: "person.badge.minus")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { await account.connect() }
                    } label: {
                        Label(tr("Connect…", "连接…"), systemImage: "person.badge.key")
                    }
                    .buttonStyle(.bordered)
                    .tint(BrandColors.cyan)
                    .disabled(account.loadConfig() == nil)
                }
            }

            Text(oAuthHelpText)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }

        Section(tr("YouTube / yt-dlp", "YouTube / yt-dlp")) {
            row(tr("yt-dlp Path", "yt-dlp 路径"), value: binaryPath ?? tr("Not found (will use yt-dlp from PATH or bundled binary)", "未找到(将用 PATH 中的 yt-dlp 或随包二进制)"))

            HStack {
                Text(tr("yt-dlp Version", "yt-dlp 版本")).foregroundStyle(BrandColors.textSecondary)
                Spacer()
                if let versionString {
                    Text(versionString).foregroundStyle(BrandColors.textPrimary)
                } else if checkingVersion {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").foregroundStyle(BrandColors.textSecondary)
                }
            }

            Button {
                Task { await checkVersion() }
            } label: {
                Label(tr("Check yt-dlp Version", "检查 yt-dlp 版本"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.cyan)
            .disabled(bridge == nil || checkingVersion)
        }

        Section(tr("Browser Cookie Source (yt-dlp)", "浏览器 Cookie 来源(yt-dlp)")) {
            Picker(tr("Cookie Source", "Cookie 来源"), selection: $cookieSourceRaw) {
                ForEach(YTCookieSource.allCases, id: \.rawValue) { src in
                    Text(src.displayName).tag(src.rawValue)
                }
            }

            if cookieSource == .file {
                HStack {
                    Text(tr("Cookie File", "Cookie 文件")).foregroundStyle(BrandColors.textSecondary)
                    Spacer()
                    Text(cookiePath.isEmpty ? tr("Not selected", "未选择") : cookiePath)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(cookiePath)
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label(tr("Choose Cookie File…", "选择 Cookie 文件…"), systemImage: "doc")
                }
                .buttonStyle(.bordered)
            }

            Text(cookieHelpText)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .task {
            if let bridge { binaryPath = await bridge.locateBinary() }
            loadOAuthDraft()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.text],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                cookiePath = url.path
            }
        }
    }

    private var cookieHelpText: String {
        switch cookieSource {
        case .none:
            return tr("No cookies used. Public content can be played/imported directly; login-required content (age-restricted/private playlists) is inaccessible.", "不使用 cookie。公开内容可直接播放/导入;登录态内容(年龄限制/私有歌单)无法访问。")
        case .safari:
            return tr("Read cookies from Safari. Grant Muses full disk access in System Settings → Privacy & Security → Full Disk Access.", "从 Safari 读取 cookie。需在 系统设置 → 隐私与安全性 → 完全磁盘访问 中授权 Muses。")
        case .chrome:
            return tr("Read cookies from Chrome. Chrome must be signed in to YouTube.", "从 Chrome 读取 cookie。Chrome 需已登录 YouTube。")
        case .firefox:
            return tr("Read cookies from Firefox. Firefox must be signed in to YouTube.", "从 Firefox 读取 cookie。Firefox 需已登录 YouTube。")
        case .file:
            return tr("Use a Netscape-format cookie file (exportable via browser extensions). Suited for cross-browser or headless scenarios.", "使用 Netscape 格式的 cookie 文件(可用浏览器扩展导出)。适合跨浏览器或无 GUI 场景。")
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private func checkVersion() async {
        guard let bridge else { return }
        checkingVersion = true
        defer { checkingVersion = false }
        versionString = await bridge.version()
        // 版本检查时顺带刷新路径。
        if let p = await bridge.locateBinary() { binaryPath = p }
    }
}