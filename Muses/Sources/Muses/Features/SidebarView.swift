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
    @State private var showProfilePopover = false
    /// YouTube 登录态:反映 cookie 来源设置,用于 Profile 副标题与头像着色。
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
                    Label(tr("YouTube Imports", "YouTube 导入"), systemImage: "play.rectangle")
                        .tag(SidebarSection.youtubeImports)
                    Label(tr("History", "历史记录"), systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.history)
                }

                // Playlists(内联)
                Section(tr("Playlists", "歌单")) {
                    ForEach(playlists, id: \.id) { playlist in
                        Label(playlist.name, systemImage: "music.note.list")
                            .tag(SidebarSection.playlists)
                            .onTapGesture {
                                NotificationCenter.default.post(
                                    name: .musesSelectPlaylist, object: playlist)
                            }
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

    /// 底部用户控件:点击弹出 Your YouTube / Sign-in / Settings / About。
    private var profileControl: some View {
        HStack(spacing: 10) {
            profileAvatar
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Your YouTube", "你的 YouTube"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(youTubeSignInSubtitle)
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

    /// 灰色人形头像(默认未登录态);已登录时使用主色高亮,直观反映登录状态。
    private var profileAvatar: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isSignedInToYouTube
                ? BrandColors.textPrimary
                : BrandColors.textSecondary)
    }

    private var isSignedInToYouTube: Bool {
        YTCookieSource(rawValue: cookieSourceRaw) ?? .none != .none
    }

    private var youTubeSignInSubtitle: String {
        isSignedInToYouTube ? tr("Signed in", "已登录") : tr("Not signed in", "未登录")
    }

    private func refreshPlaylists() {
        playlists = playlistService.fetchAll()
    }
}

/// 用户 Profile 弹出菜单:Your YouTube / Sign-in / Settings / About。
struct ProfilePopover: View {
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Binding var initialSettingsCategory: SettingsCategory?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverItem(icon: "play.rectangle",
                        title: tr("Your YouTube", "你的 YouTube")) {
                if let url = URL(string: "https://music.youtube.com") {
                    NSWorkspace.shared.open(url)
                }
                isPresented = false
            }
            popoverItem(icon: "person.badge.key",
                        title: tr("YouTube Sign-in…", "YouTube 登录…")) {
                isPresented = false
                initialSettingsCategory = .youtube
                showSettings = true
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