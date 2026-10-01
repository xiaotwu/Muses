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
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @Environment(WebHomeSessionController.self) private var webHome
    @Environment(HomeDiscoveryService.self) private var homeDiscovery

    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw: String = YTCookieSource.none.rawValue
    @AppStorage(PrefKey.ytCookiePath) private var cookiePath: String = ""
    @AppStorage(PrefKey.homeRecommendationMode) private var homeModeRaw = HomeRecommendationMode.muses.rawValue
    @State private var binaryPath: String?
    @State private var versionString: String?
    @State private var checkingVersion = false
    @State private var showFilePicker = false
    @State private var showWebHomeConsent = false
    @State private var webHomeConfigurationError: String?
    @State private var pendingRemoval: ActionConfirmation?

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
                .font(MusesTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Button {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            } label: {
                Text(tr("System Settings", "系统设置"))
            }
            .settingsAction()
        }
        .padding(.top, 4)
    }

    var body: some View {
        // Account connection and inline Home status actions share the overview.
        Group {
            if let destination {
                detail(destination)
            } else {
                accountOverview
                Section {
                    DisclosureGroup(tr("Permissions & sync", "权限与同步")) { accountDetails }
                    DisclosureGroup(tr("Personalized Home", "个性化首页管理")) { webHomeDetails }
                    DisclosureGroup(tr("Playback access", "播放访问")) { playbackCookieDetails }
                } header: { Text(tr("Permissions & access", "权限与访问")) }
            }
        }
        .actionConfirmation($pendingRemoval)
        .task {
            if let bridge { binaryPath = await bridge.locateBinary() }
            webHome.refreshDefaultBrowserSource()
        }
        .onChange(of: homeModeRaw) { _, _ in
            homeDiscovery.recommendationModeDidChange()
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

    var destination: SettingsDestination? = nil

    private var homeRecommendationSource: some View {
        LabeledContent(tr("Home source", "首页来源", zhHant: "首頁來源")) {
            SettingsGlassChoice(title: tr("Home source", "首页来源", zhHant: "首頁來源"), selection: $homeModeRaw, options: [
                .init(id: HomeRecommendationMode.muses.rawValue, title: "Muses", symbol: "music.note"),
                .init(id: HomeRecommendationMode.youtubeMusic.rawValue, title: "YouTube Music", symbol: "play.circle", isYouTube: true)
            ])
        }
        .help(tr("Recommendations stay on this Mac. YouTube Music uses your account without uploading local listening history.",
                 "推荐档案保留在本机。YouTube Music 使用你的账号，不上传本地收听历史。"))
    }

    @ViewBuilder private func detail(_ destination: SettingsDestination) -> some View {
        if destination == .diagnostics {
            Section {
                LabeledContent(tr("Playback resolver", "播放解析器")) {
                    HStack(spacing: 8) {
                        Text(versionString ?? "yt-dlp").font(MusesTypography.caption)
                        if checkingVersion { ProgressView().controlSize(.small) }
                        SettingsIconButton(title: tr("Check yt-dlp version", "检查 yt-dlp 版本"), symbol: "arrow.clockwise") {
                            Task { await checkVersion() }
                        }.disabled(bridge == nil || checkingVersion)
                    }
                }
                DisclosureGroup(tr("Resolver details", "解析器详情")) { ytDlpDetails }
            } header: { Text(tr("Resolver", "解析器")) }
            YTDlpConfigWizard()
        }
    }

    @ViewBuilder private var accountOverview: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if account.isConnecting || isWebHomeBusy {
                        ProgressView().controlSize(.small)
                    }
                    if account.isConnected {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                account.account?.channel?.title ?? tr("Connected", "已连接", zhHant: "已連接"),
                                systemImage: "checkmark.circle.fill")
                                .font(MusesTypography.body.weight(.semibold))
                                .foregroundStyle(BrandColors.textPrimary)
                            Text(tr("YouTube connected", "已连接 YouTube", zhHant: "已連接 YouTube"))
                                .font(MusesTypography.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(account.connectionState == .expired
                                  ? tr("Session expired", "登录已过期", zhHant: "登入已過期")
                                  : tr("Not connected", "未连接", zhHant: "未連接"),
                                  systemImage: "person.crop.circle.badge.questionmark")
                                .font(MusesTypography.body.weight(.semibold))
                                .foregroundStyle(BrandColors.textSecondary)
                            Text(account.connectionState == .expired
                                 ? tr("Your YouTube session expired. Sign in again to restore account access.",
                                      "YouTube 登录已过期。请重新登录以恢复账号访问。",
                                      zhHant: "YouTube 登入已過期。請重新登入以恢復帳號存取。")
                                 : tr("Sign in to import playlists and personalize Home.",
                                      "登录即可导入歌单并个性化首页。",
                                      zhHant: "登入即可匯入歌單並個人化首頁。"))
                                .font(MusesTypography.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    }
                    Spacer()
                    if account.isConnected {
                        Button(tr("Sign Out", "退出登录"), role: .destructive, action: requestDisconnect)
                        .settingsAction()
                    }
                }

                if account.isConnected {
                    HStack {
                        Text(tr("Playlists", "歌单", zhHant: "歌單"))
                            .foregroundStyle(BrandColors.textSecondary)
                        Spacer()
                        if playlistSync.isImportingAccountPlaylists {
                            ProgressView().controlSize(.small)
                            Text("\(playlistSync.accountImportCompleted)/\(playlistSync.accountImportTotal)")
                                .font(MusesTypography.caption.monospacedDigit())
                        }
                        Button {
                            Task {
                                await account.refresh()
                                await playlistSync.importAccountPlaylists()
                            }
                        } label: {
                            Image(systemName: "arrow.down.to.line")
                                .frame(width: 18, height: 18)
                        }
                        .settingsAction().controlSize(.small)
                        .disabled(account.isConnecting || playlistSync.isImportingAccountPlaylists)
                        .help(tr("Import account playlists", "导入账号歌单", zhHant: "匯入帳號歌單"))
                        .accessibilityLabel(tr("Import account playlists", "导入账号歌单", zhHant: "匯入帳號歌單"))
                    }
                    if let error = playlistSync.accountImportError {
                        Text(error).font(MusesTypography.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Text(tr("Personalized Home", "个性化首页"))
                            .foregroundStyle(BrandColors.textSecondary)
                        Spacer()
                        webHomeStatusAction
                    }
                    .padding(.top, 8)
                }

                if let error = webHomeConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(MusesTypography.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
                if let err = account.lastError {
                    Text(err).font(MusesTypography.caption).foregroundStyle(.red)
                        .padding(.top, 4)
                }
                if account.connectionState == .expired {
                    Label(
                        tr("Reconnect below to authorize this Mac again. Browser cookies and Web Home are separate.",
                           "请使用下方按钮重新授权此 Mac。浏览器 Cookie 与 Web 首页权限彼此独立。",
                           zhHant: "請使用下方按鈕重新授權此 Mac。瀏覽器 Cookie 與 Web 首頁權限彼此獨立。"),
                        systemImage: "arrow.clockwise.circle")
                        .font(MusesTypography.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                }
                if isBrowserSessionUnavailable {
                    browserSessionHelpRow
                }
            }
            .padding(.vertical, 4)

            if !account.isConnected {
                primaryAction
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            homeRecommendationSource
        } header: { Text("YouTube").font(MusesTypography.headline.weight(.semibold)) }
        Section {
                officialPageLink(
                    tr("Watch Later", "稍后观看", zhHant: "稍後觀看"),
                    url: URL(string: "https://www.youtube.com/playlist?list=WL")!
                )
                officialPageLink(
                    tr("YouTube watch history", "YouTube 观看历史", zhHant: "YouTube 觀看記錄"),
                    url: URL(string: "https://www.youtube.com/feed/history")!
                )
        } header: { Text(tr("YouTube on the web", "YouTube 网页")) }
    }

    private func officialPageLink(_ title: String, url: URL) -> some View {
        LabeledContent {
            SettingsIconButton(title: title, symbol: "arrow.up.right") {
                NSWorkspace.shared.open(url)
            }
            .help(tr("Open in your browser's YouTube account", "使用浏览器已登录的 YouTube 账号打开"))
        } label: {
            HStack(spacing: 8) {
                YouTubeMark(size: 14).accessibilityHidden(true)
                Text(title)
            }
        }
    }

    private var webHomeStatusAction: some View {
        HStack(spacing: 8) {
            SettingsStatus(title: webHome.isEnabled
                           ? "\(webHomeStatusText) · \(webHomeBrowserDescription)" : webHomeStatusText,
                           symbol: webHome.isEnabled ? "checkmark.shield" : "shield")
            SettingsIconButton(title: webHome.isEnabled
                               ? tr("Check Session", "检查会话")
                               : tr("Turn On Personalized Home", "开启个性化首页"),
                               symbol: webHome.isEnabled ? "arrow.clockwise" : "plus") {
                if webHome.isEnabled { checkSession() }
                else { enableWebHomeFlow() }
            }
            .disabled(!webHome.isBuildEnabled || isWebHomeBusy)
            .accessibilityValue(webHomeStatusText)
        }
    }

    /// Connecting continues to the separate, explicit Home consent dialog.
    @ViewBuilder
    private var primaryAction: some View {
        if !account.isOAuthConfigured {
            HStack(spacing: 6) {
                SettingsStatus(title: tr("Sign-in unavailable", "登录不可用"), symbol: "exclamationmark.triangle")
                SettingsInfoButton(title: tr("YouTube sign-in", "YouTube 登录"),
                    message: tr("YouTube sign-in is unavailable in this build. Guest browsing and playback still work.",
                                "此构建未配置 YouTube 登录；访客浏览与播放仍可正常使用。"))
            }
        } else if !account.isConnected {
            Button {
                connectAndPersonalize()
            } label: {
                Label(account.connectionState == .expired
                      ? tr("Sign In Again", "重新登录", zhHant: "重新登入")
                      : tr("Connect YouTube", "连接 YouTube", zhHant: "連接 YouTube"),
                      systemImage: "safari")
            }
            .settingsAction(prominent: true)
            .tint(BrandColors.accent)
            .disabled(account.isConnecting)
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

        VStack(alignment: .trailing, spacing: 8) {
            if account.isConnected {
                if !account.canManagePlaylists {
                    Button {
                        Task { await account.requestPlaylistManagementAccess() }
                    } label: {
                        Label(tr("Allow playlist updates…", "授权更新歌单…"),
                              systemImage: "checkmark.shield")
                    }
                    .settingsAction()
                }
            }

            Link(destination: URL(string: "https://myaccount.google.com/permissions")!) {
                Label(tr("Google access", "Google 授权"), systemImage: "arrow.up.right.square")
            }
            .settingsAction()
        }

        DisclosureGroup(tr("Permission details", "授权说明")) {
            Text(oAuthHelpText).font(MusesTypography.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }

    private var oAuthHelpText: String {
        tr("Reads your channel, likes, subscriptions and playlists. Playlist writes require confirmation. Tokens stay in Keychain; sync history stays on this Mac. Revoke access at any time.",
           "读取频道、点赞、订阅和歌单；写入歌单须经确认。令牌保存在钥匙串，同步历史保存在本机。可随时撤销授权。")
    }

    private var ytDlpDetails: some View {
        row(tr("yt-dlp Path", "yt-dlp 路径"),
            value: binaryPath ?? tr("Not found; uses PATH or the bundled resolver", "未找到；使用 PATH 或内置解析器"))
            .textSelection(.enabled)
    }

    /// Home management actions and the full privacy disclosure — normal users do not need them expanded.
    @ViewBuilder
    private var webHomeDetails: some View {
        row(
            webHome.isEnabled
                ? tr("Approved browser", "已批准的浏览器")
                : tr("Default browser", "默认浏览器"),
            value: webHomeBrowserDescription)

        VStack(alignment: .trailing, spacing: 8) {
            if webHome.isEnabled {
                Button(role: .destructive) {
                    pendingRemoval = ActionConfirmation(
                        title: tr("Turn off Personalized Home?", "关闭个性化首页？"),
                        message: tr("Clears its temporary session. Playback access and your library are retained.",
                                    "清除首页临时会话，保留播放访问设置和资料库。"),
                        actionTitle: tr("Turn off", "关闭"), action: {
                            Task {
                                await webHome.disableAndClearTemporarySession()
                                homeDiscovery.webConfigurationDidChange()
                            }
                        })
                } label: {
                    Label(tr("Turn off Home", "关闭首页"),
                          systemImage: "xmark.shield")
                }
                .settingsAction()
                .help(tr("Disable & Clear Temporary Session", "关闭并清除临时会话"))
            }
            Link(destination: URL(string: "https://music.youtube.com/")!) {
                Label(tr("Open YouTube Music", "打开 YouTube Music"),
                      systemImage: "arrow.up.right.square")
            }
            .settingsAction()

            Button(role: .destructive) {
                pendingRemoval = ActionConfirmation(
                    title: tr("Clear saved Home?", "清除首页快照？"),
                    message: tr("Removes the saved Home for this account. Playlists and listening history are retained.",
                                "移除当前账号的首页快照，保留歌单和收听历史。"),
                    actionTitle: tr("Clear", "清除"),
                    action: { homeDiscovery.clearSavedWebHomeForCurrentAccount() })
            } label: {
                Label(tr("Clear Home snapshot", "清除首页快照"), systemImage: "trash")
            }
            .settingsAction()
            .disabled(account.activeChannelID == nil)
        }

        DisclosureGroup(tr("Browser access details", "浏览器访问说明")) {
            Text(webHomeDisclosureSummary).font(MusesTypography.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }

    @ViewBuilder
    private var playbackCookieDetails: some View {
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
            .settingsAction()
            .tint(BrandColors.accent)
        }

        DisclosureGroup(tr("Playback access details", "播放访问说明")) {
            Text(cookieHelpText).font(MusesTypography.caption).foregroundStyle(BrandColors.textSecondary)
            Text(tr("Only used for playback and import. Personalized Home uses separate browser consent and never changes this selection.",
                    "仅用于播放与导入；个性化首页会单独请求浏览器授权，不会改变此选项。"))
                .font(MusesTypography.caption).foregroundStyle(BrandColors.textSecondary)
        }
    }

    private var webHomeStatusText: String {
        switch webHome.status {
        case .closed:
                webHome.isEnabled
                ? tr("Ready to check", "等待检查", zhHant: "等待檢查")
                : tr("Off", "已关闭", zhHant: "已關閉")
        case .disabledByBuild: tr("Unavailable in this build", "此构建不可用", zhHant: "此版本不可用")
        case .pendingConsent: tr("Waiting for confirmation", "等待确认", zhHant: "等待確認")
        case .checking: tr("Checking…", "正在检查…", zhHant: "正在檢查…")
        case .refreshing: tr("Refreshing…", "正在刷新…", zhHant: "正在重新整理…")
        case .available: tr("Available", "可用", zhHant: "可用")
        case .expired: tr("Session expired", "会话已过期", zhHant: "工作階段已過期")
        case .accountMismatch: tr("Account mismatch", "账号不匹配", zhHant: "帳號不相符")
        case .shapeChanged: tr("Response changed", "响应结构已变化", zhHant: "回應結構已變更")
        case .unavailable(let code): webHomeUnavailableStatusText(code)
        }
    }

    private func webHomeUnavailableStatusText(_ code: HomeFetchFailureCode) -> String {
        switch code {
        case .cookieSourceUnavailable:
            tr("Could not read browser session", "无法读取浏览器会话", zhHant: "無法讀取瀏覽器工作階段")
        case .sessionExpired:
            tr("Browser sign-in expired", "浏览器登录已过期", zhHant: "瀏覽器登入已過期")
        case .consentOrCaptchaRequired:
            tr("Browser action required", "需要在浏览器中完成操作", zhHant: "需要在瀏覽器中完成操作")
        case .identityUnavailable:
            tr("Could not verify channel", "无法核验频道", zhHant: "無法驗證頻道")
        case .rateLimited:
            tr("Temporarily rate-limited", "暂时受到频率限制", zhHant: "暫時受到頻率限制")
        case .offline:
            tr("Offline", "网络离线", zhHant: "網路離線")
        case .timedOut:
            tr("Timed out", "检查超时", zhHant: "檢查逾時")
        case .helperCrashed:
            tr("Helper stopped", "Helper 已停止", zhHant: "Helper 已停止")
        case .helperUnavailable:
            tr("Helper missing or not executable", "Helper 缺失或无法执行", zhHant: "Helper 遺失或無法執行")
        case .helperUntrusted:
            tr("Helper signature verification failed", "Helper 签名验证失败", zhHant: "Helper 簽章驗證失敗")
        case .protocolMismatch:
            tr("Helper version mismatch", "Helper 版本不匹配", zhHant: "Helper 版本不相符")
        case .responseTooLarge:
            tr("Response too large", "响应过大", zhHant: "回應過大")
        case .malformedResponse:
            tr("Invalid helper response", "Helper 响应无效", zhHant: "Helper 回應無效")
        case .oauthRequired:
            tr("YouTube account required", "需要连接 YouTube 账号", zhHant: "需要連接 YouTube 帳號")
        case .accountMismatch:
            tr("Account mismatch", "账号不匹配", zhHant: "帳號不相符")
        case .shapeChanged:
            tr("Response changed", "响应结构已变化", zhHant: "回應結構已變更")
        case .disabled:
            tr("Off", "已关闭", zhHant: "已關閉")
        case .baselineUnavailable:
            tr("Public Home unavailable", "公共首页暂不可用", zhHant: "公共首頁暫不可用")
        }
    }

    private var webHomeDisclosureSummary: String {
        tr(
            "Off by default. With separate consent, an isolated helper reads your browser session for Home only. It never controls playback or playlist writes, and does not save browser credentials.",
            "默认关闭。单独授权后，隔离助手仅读取浏览器会话以显示首页；不参与播放或歌单写入，也不保存浏览器凭据。")
    }

    private var webHomeConsentMessage: String {
        tr(
            "Muses will use the detected default browser (\(webHomeConsentBrowserName)) only for isolated, read-only Home requests. This source stays fixed until you disconnect Web Home; changing the system default browser will not switch it silently. Browser extraction uses a permission-restricted temporary jar that is deleted after the one-shot helper exits. The Web channel must exactly match the connected OAuth channel. YouTube may require you to sign in, complete consent or a CAPTCHA, and this private Web access remains subject to YouTube's terms. No playback, Push, playlist write, or user-data truth will depend on it.",
            "Muses 只会把识别到的默认浏览器（\(webHomeConsentBrowserName)）用于隔离、只读的首页请求。该来源会固定到你断开 Web 首页为止；更改系统默认浏览器不会让它静默切换。浏览器提取使用权限受限的临时 jar，并在一次性 Helper 退出后删除；Web 频道必须与已连接的 OAuth 频道完全一致。YouTube 可能要求你登录、完成同意或验证码，此私有 Web 访问仍受 YouTube 条款约束。播放、Push、歌单写入和用户数据真相均不会依赖它。", zhHant: "Muses 只會把識別到的預設瀏覽器（\(webHomeConsentBrowserName)）用於隔離、只讀的首頁請求。該來源會固定到你斷開 Web 首頁為止；更改系統預設瀏覽器不會讓它靜默切換。瀏覽器提取使用權限受限的臨時 jar，並在一次性 Helper 結束後刪除；Web 頻道必須與已連接的 OAuth 頻道完全一致。YouTube 可能要求你登入、完成同意或驗證碼，此私有 Web 訪問仍受 YouTube 條款約束。播放、Push、歌單寫入和用戶數據真相均不會依賴它。")
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
                      "\(applicationName)（暂不支持）", zhHant: "\(applicationName)（暫不支持）")
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
                .font(MusesTypography.callout)
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
                              "\(label)：正在显示已保存数据", zhHant: "\(label)：正在顯示已保存數據")
                         : tr("\(label): unavailable", "\(label)：暂不可用", zhHant: "\(label)：暫不可用"))
                        .font(MusesTypography.caption.weight(.semibold))
                    Text(message).font(MusesTypography.caption2).lineLimit(2)
                }
            }
            .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func requestDisconnect() {
        pendingRemoval = ActionConfirmation(
            title: tr("Sign out of YouTube?", "退出 YouTube 登录？"),
            message: tr("Disconnects this account and clears its Home session. Your local library is retained.",
                        "断开当前账号并清除对应首页会话，保留本机资料库。"),
            actionTitle: tr("Sign out", "退出登录"), action: {
                Task { await webHome.accountDidChange(); account.disconnect() }
            })
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
