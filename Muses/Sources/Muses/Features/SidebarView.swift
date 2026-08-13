import SwiftUI
import AppKit
import SwiftData

/// Apple Music 风格侧边栏:Logo 头 / 导航项 / 内联歌单 / 用户控件。
struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackService.self) private var playback
    @State private var playlists: [Playlist] = []
    @State private var showProfilePopover = false

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
                .font(.headline)
                .fontWeight(.bold)
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

    /// 底部用户控件:点击弹出 Profile / Settings / About。
    private var profileControl: some View {
        HStack(spacing: 10) {
            logoImage
                .frame(width: 28, height: 28)
                .cornerRadius(14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Profile", "个人"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(playback.state.track?.title ?? tr("Not Playing", "未播放"))
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
                           isPresented: $showProfilePopover)
        }
    }

    private func refreshPlaylists() {
        playlists = playlistService.fetchAll()
    }
}

/// 用户 Profile 弹出菜单:Profile / Settings / About。
struct ProfilePopover: View {
    @Binding var showSettings: Bool
    @Binding var showAbout: Bool
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverItem(icon: "person.circle", title: tr("Profile", "个人资料")) {
                if let url = URL(string: "https://music.youtube.com") {
                    NSWorkspace.shared.open(url)
                }
                isPresented = false
            }
            popoverItem(icon: "gearshape", title: tr("Settings", "设置")) {
                isPresented = false
                showSettings = true
            }
            popoverItem(icon: "info.circle", title: tr("About", "关于")) {
                isPresented = false
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