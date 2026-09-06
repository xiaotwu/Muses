import SwiftUI
import UniformTypeIdentifiers

private struct YTDlpBridgeEnvironmentKey: EnvironmentKey {
    static let defaultValue: YTDlpBridge? = nil
}

extension EnvironmentValues {
    var ytDlpBridge: YTDlpBridge? {
        get { self[YTDlpBridgeEnvironmentKey.self] }
        set { self[YTDlpBridgeEnvironmentKey.self] = newValue }
    }
}

struct YouTubeSettingsView: View {
    @Environment(\.ytDlpBridge) private var bridge
    // Real Google OAuth account — credentials live in the Keychain with a minimal read-only scope.
    @Environment(YouTubeAccountService.self) private var account
    @Environment(WebHomeSessionController.self) private var webHome
    @Environment(HomeDiscoveryService.self) private var homeDiscovery

    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw: String = YTCookieSource.none.rawValue
    @AppStorage(PrefKey.ytCookiePath) private var cookiePath: String = ""
    /// Normal users see only the status card and one-click connect; technical details collapse into Advanced.
    @AppStorage(PrefKey.ytShowAdvanced) private var showAdvanced = false

    @State private var binaryPath: String?
    @State private var versionString: String?
    @State private var checkingVersion = false
    @State private var showFilePicker = false
    @State private var showWebHomeConsent = false
    @State private var webHomeConfigurationError: String?

    private var cookieSource: YTCookieSource {
        YTCookieSource(rawValue: cookieSourceRaw) ?? .none
    }

    private var isWebHomeBusy: Bool {
        webHome.status == .checking || webHome.status == .refreshing
    }

    /// Cookie-stage failures usually stem from macOS permissions (Full Disk Access/Keychain) or
    /// the browser session itself; surface a direct route to System Settings instead of repeated trial and error.
    private var isBrowserSessionUnavailable: Bool {
        if case .unavailable(let code) = webHome.status, code == .cookieSourceUnavailable {
            return true
        }
        return false
    }

    private var browserSessionHelpRow: some View {
        HStack(spacing: 6) {
            Label(
                tr("Grant Full Disk Access to Muses in System Settings → Privacy & Security → Full Disk Access.",
                   "请在 系统设置 → 隐私与安全性 → 完全磁盘访问 中授权 Muses。"),
                systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Button {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            } label: {
                Text(tr("System Settings", "系统设置"))
            }
            .buttonStyle(.link)
        }
        .padding(.top, 4)
    }

    var body: some View {
        // Normal mode: one status card + one primary action; yt-dlp, permission, and cookie
        // details all collapse into Advanced so connecting stays clear for regular users.
        Section(tr("YouTube", "YouTube")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if account.isConnecting || isWebHomeBusy {
                        ProgressView().controlSize(.small)
                    }
                    if account.isConnected {
                        Label(
                            account.account?.channel?.title ?? tr("Connected", "已连接"),
                            systemImage: "checkmark.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(BrandColors.textPrimary)
                    } else {
                        Label(tr("Not connected", "未连接"),
                              systemImage: "person.crop.circle.badge.questionmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    Spacer()
                }

                if account.isConnected {
                    HStack {
                        Text(tr("Personalized Home", "个性化首页"))
                            .foregroundStyle(BrandColors.textSecondary)
                        Spacer()
                        Text(
                            webHome.isEnabled
                                ? "\(webHomeStatusText) · \(webHomeBrowserDescription)"
                                : webHomeStatusText)
                            .foregroundStyle(webHome.isEnabled
                                ? BrandColors.textPrimary : BrandColors.textSecondary)
                            .font(.callout)
                    }
                    .padding(.top, 8)
                }

                if let error = webHomeConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
                if let err = account.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .padding(.top, 4)
                }
                if isBrowserSessionUnavailable {
                    browserSessionHelpRow
                }
            }
            .padding(.vertical, 4)

            primaryAction
                .padding(.top, 4)

            DisclosureGroup(isExpanded: $showAdvanced) {
                accountDetails
                ytDlpDetails
                webHomeDetails
                playbackCookieDetails
            } label: {
                Label(tr("Advanced", "高级"), systemImage: "gearshape.2")
            }
            .padding(.top, 6)
        }
        .task {
            if let bridge { binaryPath = await bridge.locateBinary() }
            webHome.refreshDefaultBrowserSource()
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
        .alert(
            tr("Allow Web Home to use the default browser session?",
               "允许 Web 首页使用默认浏览器会话吗？"),
            isPresented: $showWebHomeConsent
        ) {
            Button(tr("Cancel", "取消"), role: .cancel) {
                webHomeConfigurationError = nil
                webHome.cancelPendingConsent()
            }
            Button(tr("Allow and Check", "允许并检查")) {
                do {
                    try webHome.enableUsingDefaultBrowser()
                    Task {
                        await webHome.probeSession()
                        if case .available = webHome.status {
                            homeDiscovery.webConfigurationDidChange()
                        }
                    }
                } catch {
                    webHomeConfigurationError = webHomeConfigurationMessage(error)
                    webHome.cancelPendingConsent()
                }
            }
        } message: {
            Text(webHomeConsentMessage)
        }
    }

    /// One-click state machine: connect OAuth first, then continue straight into the Home consent;
    /// connected-but-disabled offers only the enable action; when enabled, the single action is refreshing the session.
    @ViewBuilder
    private var primaryAction: some View {
        if !account.isOAuthConfigured {
            Label(
                tr("YouTube sign-in is unavailable in this build. Guest browsing and playback still work.",
                   "此构建未配置 YouTube 登录；访客浏览与播放仍可正常使用。"),
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        } else if !account.isConnected {
            Button {
                connectAndPersonalize()
            } label: {
                Label(tr("Connect YouTube", "连接 YouTube"),
                      systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
            .disabled(account.isConnecting)
        } else if !webHome.isEnabled {
            Button {
                enableWebHomeFlow()
            } label: {
                Label(tr("Turn On Personalized Home", "开启个性化首页"),
                      systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
            .disabled(!webHome.isBuildEnabled || isWebHomeBusy)
        } else {
            Button {
                checkSession()
            } label: {
                Label(tr("Check Session", "检查会话"), systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
            .disabled(isWebHomeBusy)
        }
    }

    /// Right after connecting, present the dedicated Home consent; cookie reuse still requires the user
    /// to explicitly allow it in the dialog — it is never enabled silently.
    private func connectAndPersonalize() {
        Task {
            await account.connect()
            if account.isConnected {
                enableWebHomeFlow()
            }
        }
    }

    private func enableWebHomeFlow() {
        webHomeConfigurationError = nil
        do {
            try webHome.prepareDefaultBrowserConsent()
            showWebHomeConsent = true
        } catch {
            webHomeConfigurationError = webHomeConfigurationMessage(error)
            webHome.cancelPendingConsent()
        }
    }

    private func checkSession() {
        Task {
            await webHome.probeSession()
            if case .available = webHome.status {
                homeDiscovery.webConfigurationDidChange()
            }
        }
    }

    /// OAuth grant details and manual management actions — for advanced users only.
    @ViewBuilder
    private var accountDetails: some View {
        if let title = account.account?.channel?.title, !title.isEmpty {
            row(tr("Channel", "频道"), value: title)
        }
        permissionRow(
            tr("Read account data", "读取账号数据"),
            granted: account.canReadAccount)
        permissionRow(
            tr("Manage owned playlists", "管理自有歌单"),
            granted: account.canManagePlaylists)
        accountFailure(
            tr("Channel", "频道"), state: account.channelState)
        accountFailure(
            tr("Playlists", "歌单"), state: account.playlistsState)
        accountFailure(
            tr("Subscriptions", "订阅"), state: account.subscriptionsState)
        accountFailure(
            tr("Liked videos", "点赞视频"), state: account.likedVideosState)

        HStack {
            if account.isConnected {
                if !account.canManagePlaylists {
                    Button {
                        Task { await account.requestPlaylistManagementAccess() }
                    } label: {
                        Label(tr("Allow Playlist Updates…", "允许更新歌单…"),
                              systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    Task {
                        await webHome.accountDidChange()
                        account.disconnect()
                    }
                } label: {
                    Label(tr("Disconnect", "断开连接"), systemImage: "person.badge.minus")
                }
                .buttonStyle(.bordered)
            }

            Link(destination: URL(string: "https://myaccount.google.com/permissions")!) {
                Label(tr("Manage Google Access", "管理 Google 授权"), systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link)
        }

        Text(oAuthHelpText)
            .font(.caption)
            .foregroundStyle(BrandColors.textSecondary)
    }

    private var oAuthHelpText: String {
        tr("Muses opens Google sign-in in your default browser. It reads your channel identity, liked videos, subscriptions, and playlists to personalize Home. With your confirmation, it can update playlists you own. Tokens stay in macOS Keychain; playlist sync history stays on this Mac. You can disconnect here or revoke Muses from your Google Account at any time.",
           "Muses 会在默认浏览器中打开 Google 登录。它会读取你的频道身份、点赞视频、订阅和歌单来个性化首页；经你确认后，也可以更新你拥有的歌单。令牌保存在 macOS 钥匙串，同步历史仅保存在本机。你可以随时在此断开连接，或在 Google 账号中撤销 Muses 的访问权限。")
    }

    @ViewBuilder
    private var ytDlpDetails: some View {
        Divider().padding(.vertical, 8)
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
        .tint(BrandColors.magenta)
        .disabled(bridge == nil || checkingVersion)
    }

    /// Home management actions and the full privacy disclosure — normal users do not need them expanded.
    @ViewBuilder
    private var webHomeDetails: some View {
        Divider().padding(.vertical, 8)
        row(
            webHome.isEnabled
                ? tr("Approved browser", "已批准的浏览器")
                : tr("Default browser", "默认浏览器"),
            value: webHomeBrowserDescription)

        HStack {
            if webHome.isEnabled {
                Button(role: .destructive) {
                    Task {
                        await webHome.disableAndClearTemporarySession()
                        homeDiscovery.webConfigurationDidChange()
                    }
                } label: {
                    Label(tr("Disable & Clear Temporary Session", "关闭并清除临时会话"),
                          systemImage: "xmark.shield")
                }
                .buttonStyle(.bordered)
            }
            Link(destination: URL(string: "https://music.youtube.com/")!) {
                Label(tr("Open YouTube Music", "打开 YouTube Music"),
                      systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link)

            Button {
                homeDiscovery.clearSavedWebHomeForCurrentAccount()
            } label: {
                Label(tr("Clear Saved Web Home", "清除已保存的 Web 首页"),
                      systemImage: "trash")
            }
            .buttonStyle(.link)
            .disabled(account.activeChannelID == nil)
        }

        Text(webHomeDisclosureSummary)
            .font(.caption)
            .foregroundStyle(BrandColors.textSecondary)
    }

    @ViewBuilder
    private var playbackCookieDetails: some View {
        Divider().padding(.vertical, 8)
        Picker(tr("Playback Cookie Source", "播放 Cookie 来源"), selection: $cookieSourceRaw) {
            ForEach(YTCookieSource.settingsCases, id: \.rawValue) { src in
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
            .tint(BrandColors.magenta)
        }

        Text(cookieHelpText)
            .font(.caption)
            .foregroundStyle(BrandColors.textSecondary)

        Text(tr(
            "This setting is only for yt-dlp playback and import. Personalized Home detects the supported default browser separately and never changes this selection.",
            "此设置仅用于 yt-dlp 播放与导入。个性化首页会单独识别受支持的默认浏览器，且绝不会修改这里的选择。"))
            .font(.caption)
            .foregroundStyle(BrandColors.textSecondary)
    }

    private var webHomeStatusText: String {
        switch webHome.status {
        case .closed:
            webHome.isEnabled
                ? tr("Ready to check", "等待检查")
                : tr("Off", "已关闭")
        case .disabledByBuild: tr("Unavailable in this build", "此构建不可用")
        case .pendingConsent: tr("Waiting for confirmation", "等待确认")
        case .checking: tr("Checking…", "正在检查…")
        case .refreshing: tr("Refreshing…", "正在刷新…")
        case .available: tr("Available", "可用")
        case .expired: tr("Session expired", "会话已过期")
        case .accountMismatch: tr("Account mismatch", "账号不匹配")
        case .shapeChanged: tr("Response changed", "响应结构已变化")
        case .unavailable(let code): webHomeUnavailableStatusText(code)
        }
    }

    private func webHomeUnavailableStatusText(_ code: HomeFetchFailureCode) -> String {
        switch code {
        case .cookieSourceUnavailable:
            tr("Could not read browser session", "无法读取浏览器会话")
        case .sessionExpired:
            tr("Browser sign-in expired", "浏览器登录已过期")
        case .consentOrCaptchaRequired:
            tr("Browser action required", "需要在浏览器中完成操作")
        case .identityUnavailable:
            tr("Could not verify channel", "无法核验频道")
        case .rateLimited:
            tr("Temporarily rate-limited", "暂时受到频率限制")
        case .offline:
            tr("Offline", "网络离线")
        case .timedOut:
            tr("Timed out", "检查超时")
        case .helperCrashed:
            tr("Helper stopped", "Helper 已停止")
        case .protocolMismatch:
            tr("Helper version mismatch", "Helper 版本不匹配")
        case .responseTooLarge:
            tr("Response too large", "响应过大")
        case .malformedResponse:
            tr("Invalid helper response", "Helper 响应无效")
        case .oauthRequired:
            tr("YouTube account required", "需要连接 YouTube 账号")
        case .accountMismatch:
            tr("Account mismatch", "账号不匹配")
        case .shapeChanged:
            tr("Response changed", "响应结构已变化")
        case .disabled:
            tr("Off", "已关闭")
        case .baselineUnavailable:
            tr("Public Home unavailable", "公共首页暂不可用")
        }
    }

    private var webHomeDisclosureSummary: String {
        tr(
            "Off by default. Muses detects Safari, Chrome, or Firefox when it is your default browser, then asks once before a separate one-shot helper reads that browser session locally. It is read-only, never controls playback or playlist writes, and keeps no Cookie, auth hash, raw response, or continuation token in the app's saved data.",
            "默认关闭。当 Safari、Chrome 或 Firefox 是系统默认浏览器时，Muses 会自动识别，并在独立的一次性 Helper 本机读取该浏览器会话前单独询问一次。该能力只读，不参与播放或歌单写入，也不会在 App 的持久数据中保存 Cookie、鉴权哈希、原始响应或 continuation token。")
    }

    private var webHomeConsentMessage: String {
        tr(
            "Muses will use the detected default browser (\(webHomeConsentBrowserName)) only for isolated, read-only Home requests. This source stays fixed until you disconnect Web Home; changing the system default browser will not switch it silently. Browser extraction uses a permission-restricted temporary jar that is deleted after the one-shot helper exits. The Web channel must exactly match the connected OAuth channel. YouTube may require you to sign in, complete consent or a CAPTCHA, and this private Web access remains subject to YouTube's terms. No playback, Push, playlist write, or user-data truth will depend on it.",
            "Muses 只会把识别到的默认浏览器（\(webHomeConsentBrowserName)）用于隔离、只读的首页请求。该来源会固定到你断开 Web 首页为止；更改系统默认浏览器不会让它静默切换。浏览器提取使用权限受限的临时 jar，并在一次性 Helper 退出后删除；Web 频道必须与已连接的 OAuth 频道完全一致。YouTube 可能要求你登录、完成同意或验证码，此私有 Web 访问仍受 YouTube 条款约束。播放、Push、歌单写入和用户数据真相均不会依赖它。")
    }

    private var webHomeBrowserDescription: String {
        if let approved = webHome.approvedBrowserSource {
            return approved.displayName
        }
        switch webHome.defaultBrowserResolution {
        case .supported(_, let applicationName, _):
            return applicationName
        case .unsupported(let applicationName, _):
            return tr("\(applicationName) (not supported)",
                      "\(applicationName)（暂不支持）")
        case .unavailable:
            return tr("Could not detect", "无法识别")
        }
    }

    private var webHomeConsentBrowserName: String {
        switch webHome.defaultBrowserResolution {
        case .supported(_, let applicationName, _),
             .unsupported(let applicationName, _):
            return applicationName
        case .unavailable:
            return tr("Unavailable", "不可用")
        }
    }

    private func webHomeConfigurationMessage(_ error: Error) -> String {
        switch error as? WebHomeConfigurationError {
        case .disabledByBuild:
            tr("Web Home is disabled in this build.", "此构建已禁用 Web 首页。")
        case .oauthRequired:
            tr("Connect your YouTube account before enabling personalized Home.",
               "开启个性化首页前，请先连接 YouTube 账号。")
        case .defaultBrowserUnavailable:
            tr("Muses could not detect the default browser. Choose Safari, Chrome, or Firefox as the macOS default browser, then try again.",
               "Muses 无法识别默认浏览器。请先把 Safari、Chrome 或 Firefox 设为 macOS 默认浏览器，然后重试。")
        case .defaultBrowserUnsupported:
            tr("The current default browser is not supported for isolated personalized Home access. Choose Safari, Chrome, or Firefox as the macOS default browser, then try again.",
               "当前默认浏览器暂不支持隔离式个性化首页访问。请先把 Safari、Chrome 或 Firefox 设为 macOS 默认浏览器，然后重试。")
        case nil:
            tr("Personalized Home could not be enabled.", "无法开启个性化首页。")
        }
    }

    private var cookieHelpText: String {
        switch cookieSource {
        case .none:
            return tr("No cookies used. Public content can be played/imported directly; login-required content (age-restricted/private playlists) is inaccessible.", "不使用 cookie。公开内容可直接播放/导入;登录态内容(年龄限制/私有歌单)无法访问。")
        case .safari:
            return tr("Read cookies from Safari. Grant Muses full disk access in System Settings → Privacy & Security → Full Disk Access.", "从 Safari 读取 cookie。需在 系统设置 → 隐私与安全性 → 完全磁盘访问 中授权 Muses。")
        case .chrome:
            return tr("Read cookies from Chrome via yt-dlp. Chrome should be signed in to YouTube. Quit Chrome if extraction fails.", "通过 yt-dlp 从 Chrome 读取 cookie。Chrome 需已登录 YouTube。若提取失败,请先退出 Chrome。")
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

    private func permissionRow(_ label: String, granted: Bool) -> some View {
        HStack {
            Text(label).foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Label(
                granted ? tr("Allowed", "已允许") : tr("Not allowed", "未允许"),
                systemImage: granted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(granted ? BrandColors.textPrimary : BrandColors.textSecondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func accountFailure<Value>(_ label: String,
                                       state: LoadState<Value>) -> some View {
        if let message = state.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isStale
                         ? tr("\(label): showing saved data",
                              "\(label)：正在显示已保存数据")
                         : tr("\(label): unavailable", "\(label)：暂不可用"))
                        .font(.caption.weight(.semibold))
                    Text(message).font(.caption2).lineLimit(2)
                }
            }
            .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func checkVersion() async {
        guard let bridge else { return }
        checkingVersion = true
        defer { checkingVersion = false }
        versionString = await bridge.version()
        // Refresh the binary path alongside the version check.
        if let p = await bridge.locateBinary() { binaryPath = p }
    }
}