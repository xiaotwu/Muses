import SwiftUI
import AppKit
import SwiftData

/// Apple Music 风格侧边栏:Logo 头 / 导航项 / 内联歌单 / 用户控件。
struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Binding var initialSettingsCategory: SettingsCategory?
    @Environment(PlaylistService.self) private var playlistService
    @State private var playlists: [Playlist] = []
    @Query(sort: \YouTubeImport.importedAt, order: .reverse) private var ytImports: [YouTubeImport]
    @State private var showProfilePopover = false
    /// P2 — YouTube 账户(真实 Google OAuth):驱动 Profile 标题/连接态/头像着色。
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    /// cookie 来源(yt-dlp 播放用),仅当 OAuth 未连接时作为登录态回退显示。
    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw = YTCookieSource.none.rawValue

    var body: some View {
        VStack(spacing: 0) {
            // Logo 头
            sidebarHeader

            // 导航列表
            List(selection: $selection) {
                // 顶级项
                Section {
                    Label(tr("Search", "搜索"), systemImage: "magnifyingglass")
                        .tag(SidebarSection.search)
                    Label(tr("Home", "首页"), systemImage: "house")
                        .tag(SidebarSection.home)
                    Label(tr("New", "新发现"), systemImage: "sparkles")
                        .tag(SidebarSection.new)
                }

                // Library
                Section(tr("Library", "资料库")) {
                    Label(tr("Pins", "钉选"), systemImage: "pin")
                        .tag(SidebarSection.pins)
                    Label(tr("Recently", "最近"), systemImage: "clock")
                        .tag(SidebarSection.recently)
                    Label(tr("Artists", "艺术家"), systemImage: "person.2")
                        .tag(SidebarSection.artists)
                    Label(tr("Albums", "专辑"), systemImage: "square.stack")
                        .tag(SidebarSection.albums)
                    Label(tr("Songs", "歌曲"), systemImage: "music.note")
                        .tag(SidebarSection.songs)
                    Label(tr("History", "历史记录"), systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.history)
                    Label(tr("Inbox", "收件箱"), systemImage: "tray")
                        .tag(SidebarSection.inbox)
                }

                // Playlists(内联,合并本地歌单与 YouTube 导入歌单)
                Section(tr("Playlists", "歌单")) {
                    ForEach(mergedItems) { item in
                        PlaylistSidebarRow(item: item) { handlePlaylistTap(item) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // 底部用户控件
            profileControl
        }
        .frame(width: 232)
        .onAppear { refreshPlaylists() }
        .onReceive(NotificationCenter.default.publisher(for: .musesPlaylistsChanged)) { _ in
            refreshPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesSelectPlaylist)) { note in
            selection = .playlists
        }
        .onReceive(NotificationCenter.default.publisher(for: .musesNavigateYouTubeImport)) { _ in
            // YouTube 歌单与本地歌单共享侧边栏「Playlists」分组,选中时高亮该分组。
            selection = .playlists
        }
    }

    /// 合并本地歌单与 YouTube 导入歌单(钉选置顶,其余按时间倒序)。
    private var mergedItems: [SidebarPlaylistItem] {
        PlaylistSidebarAdapter.merged(local: playlists, youTube: ytImports)
    }

    /// 侧边栏歌单行点击路由:本地 → `.musesSelectPlaylist`;YouTube → `.musesNavigateYouTubeImport`。
    private func handlePlaylistTap(_ item: SidebarPlaylistItem) {
        switch item.origin {
        case .local:
            if let pid = item.playlistId,
               let playlist = playlists.first(where: { $0.id == pid }) {
                NotificationCenter.default.post(name: .musesSelectPlaylist, object: playlist)
            }
        case .youtube:
            if let yid = item.youTubeImportId,
               let imp = ytImports.first(where: { $0.id == yid }) {
                NotificationCenter.default.post(name: .musesNavigateYouTubeImport, object: imp)
            }
        }
    }

    /// Logo 头:Logo 图标 + 应用名。
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            logoImage
                .frame(width: 28, height: 28)
                .cornerRadius(6)
            Text("Muses")
                .font(BrandFont.muses(24))
                .foregroundStyle(BrandColors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// 从 bundle 加载 logo.png(优先 main bundle,回退 module bundle)。
    private var logoImage: some View {
        Group {
            let url = Bundle.main.url(forResource: "logo", withExtension: "png")
                ?? Bundle.module.url(forResource: "logo", withExtension: "png")
            if let url, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BrandColors.magenta)
                    .overlay(Text("M").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BrandColors.textPrimary))
            }
        }
    }

    /// 底部用户控件:点击弹出 You / Connect / Settings / About。
    private var profileControl: some View {
        HStack(spacing: 10) {
            profileAvatar
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("You", "你"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(youTubeStatusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.up")
                .font(.caption2)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { showProfilePopover.toggle() }
        .popover(isPresented: $showProfilePopover, arrowEdge: .top) {
            ProfilePopover(showSettings: $showSettings,
                           showAbout: $showAbout,
                           initialSettingsCategory: $initialSettingsCategory,
                           isPresented: $showProfilePopover)
        }
    }

    /// 灰色人形头像(默认未登录态);已连接 YouTube(OAuth)或已设 cookie 时使用主色高亮。
    private var profileAvatar: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isYouTubeConnected
                ? BrandColors.textPrimary
                : BrandColors.textSecondary)
    }

    /// 已连接:OAuth 账户连接,或 yt-dlp cookie 来源已设(回退)。
    private var isYouTubeConnected: Bool {
        youTubeAccount.isConnected
            || (YTCookieSource(rawValue: cookieSourceRaw) ?? .none) != .none
    }

    /// Profile 副标题:优先 OAuth 账户标题;否则回退 cookie 来源登录态。
    private var youTubeStatusSubtitle: String {
        if youTubeAccount.isConnected {
            if let title = youTubeAccount.account?.channel?.title, !title.isEmpty {
                return title
            }
            return tr("Connected", "已连接")
        }
        let cookieOn = (YTCookieSource(rawValue: cookieSourceRaw) ?? .none) != .none
        return cookieOn ? tr("Cookie sign-in", "Cookie 登录") : tr("Not connected", "未连接")
    }

    private func refreshPlaylists() {
        playlists = playlistService.fetchAll()
    }
}

/// 用户 Profile 弹出菜单:You / Connect to YouTube / Settings / About。
struct ProfilePopover: View {
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Binding var initialSettingsCategory: SettingsCategory?
    @Binding var isPresented: Bool
    @Environment(YouTubeAccountService.self) private var youTubeAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverItem(icon: "play.rectangle",
                        title: tr("You", "你")) {
                if let url = URL(string: "https://music.youtube.com") {
                    NSWorkspace.shared.open(url)
                }
                isPresented = false
            }
            // P2 — 真实 Google OAuth 连接(非 cookie 跳转)。已配置凭证 → 浏览器授权;
            // 未配置 → 跳转设置页填入 Google Cloud OAuth Client ID/Secret/Redirect URI。
            if youTubeAccount.isConnected {
                popoverItem(icon: "person.badge.minus",
                            title: tr("Disconnect from YouTube…", "断开 YouTube 连接…")) {
                    isPresented = false
                    youTubeAccount.disconnect()
                }
            } else {
                popoverItem(icon: "person.badge.key",
                            title: tr("Connect to YouTube…", "连接到 YouTube…")) {
                    isPresented = false
                    if youTubeAccount.loadConfig() == nil {
                        initialSettingsCategory = .youtube
                        showSettings = true
                    } else {
                        Task { await youTubeAccount.connect() }
                    }
                }
            }
            popoverItem(icon: "gearshape", title: tr("Settings", "设置")) {
                isPresented = false
                initialSettingsCategory = nil
                showSettings = true
            }
            popoverItem(icon: "info.circle", title: tr("About", "关于")) {
                isPresented = false
                initialSettingsCategory = .about
                showAbout = true
                showSettings = true
            }
        }
        .padding(4)
        .frame(width: 200)
        .background(.ultraThinMaterial)
    }

    private func popoverItem(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(BrandColors.textSecondary)
                Text(title)
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cornerRadius(6)
    }
}

extension Notification.Name {
    static let musesSelectPlaylist = Notification.Name("muses.selectPlaylist")
    static let musesPlaylistsChanged = Notification.Name("muses.playlistsChanged")
}