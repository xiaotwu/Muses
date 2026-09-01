import SwiftUI
import AppKit

/// Settings category enum.
enum SettingsCategory: String, Hashable, CaseIterable {
    case general, playback, audioQuality, appearance, youtube, lyrics, desktop, updates, about

    var label: String {
        switch self {
        case .general:      return tr("General", "通用")
        case .playback:     return tr("Playback", "播放")
        case .audioQuality: return tr("Quality", "清晰度")
        case .appearance:   return tr("Appearance", "外观")
        case .youtube:      return "YouTube"
        case .lyrics:       return tr("Lyrics", "歌词")
        case .desktop:      return tr("Desktop", "桌面")
        case .updates:      return tr("Updates", "更新")
        case .about:        return tr("About", "关于")
        }
    }

    var systemIcon: String? {
        switch self {
        case .general:      return "gear"
        case .playback:     return "play.circle"
        case .audioQuality: return "sparkles.tv"
        case .appearance:   return "paintbrush"
        case .youtube:      return nil
        case .lyrics:       return "text.alignleft"
        case .desktop:      return "menubar.rectangle"
        case .updates:      return "arrow.triangle.2.circlepath"
        case .about:        return "info.circle"
        }
    }
}

enum SettingsNavigationPolicy {
    static func title(
        selectedCategory: SettingsCategory,
        showingDetail: Bool
    ) -> String {
        showingDetail ? selectedCategory.label : tr("Settings", "设置")
    }
}

/// Apple Music–style Account page in the main content slot.
struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @State private var selectedCategory: SettingsCategory
    @State private var showingDetail: Bool
    @State private var escapeMonitor: Any?
    @Environment(YouTubeAccountService.self) private var youTubeAccount
    /// Shares the same preference key as the YouTubeSettingsView "Advanced" disclosure.
    @AppStorage(PrefKey.ytShowAdvanced) private var showYtAdvanced = false

    init(isPresented: Binding<Bool>, initialCategory: SettingsCategory? = nil) {
        _isPresented = isPresented
        _selectedCategory = State(initialValue: initialCategory ?? .general)
        _showingDetail = State(initialValue: initialCategory != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if showingDetail {
                    ChromeIconButton(
                        systemName: "chevron.left",
                        help: tr("Back", "返回"),
                        accessibility: tr("Back", "返回")
                    ) { showingDetail = false }
                }
                Text(SettingsNavigationPolicy.title(
                    selectedCategory: selectedCategory,
                    showingDetail: showingDetail
                ))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ChromeIconButton(
                    systemName: "xmark",
                    help: tr("Close", "关闭"),
                    accessibility: tr("Close Settings", "关闭设置")
                ) { close() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // The main window uses a hidden title bar. Keep this non-interactive
            // header as its native background-drag region while the panel is open.

            if showingDetail {
                Form {
                    detailForm
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .blocksWindowDrag()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        accountHeader
                        categoryList
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .blocksWindowDrag()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onExitCommand { handleEscape() }
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    handleEscape()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    @ViewBuilder
    private var detailForm: some View {
        switch selectedCategory {
        case .general:
            GPUSettingsView()
            NotificationsSettingsView()
            LanguageSettingsView()
            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label(tr("Quit Muses", "退出 Muses"), systemImage: "power")
                }
            }
        case .playback:
            PlaybackSettingsView()
        case .audioQuality:
            AudioQualitySettingsView()
        case .appearance:
            ThemeSettingsView()
        case .youtube:
            // Normal mode: only the YouTubeSettingsView one-click panel; yt-dlp setup and hover
            // preview are technical details shown together with the Advanced disclosure.
            YouTubeSettingsView()
            if showYtAdvanced {
                YTDlpConfigWizard()
            }
        case .lyrics:
            LyricsSettingsView()
        case .desktop:
            DesktopSettingsView()
        case .updates:
            UpdatesSettingsView()
        case .about:
            AboutSettingsView()
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(SettingsCategory.allCases, id: \.self) { cat in
                Button {
                    selectedCategory = cat
                    showingDetail = true
                } label: {
                    HStack(spacing: 12) {
                        categoryIcon(cat)
                            .frame(width: 28, height: 28)
                        Text(cat.label)
                            .foregroundStyle(BrandColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if cat != SettingsCategory.allCases.last {
                    Divider().opacity(0.12)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryIcon(_ category: SettingsCategory) -> some View {
        if category == .youtube {
            YouTubeMark(size: 15)
                .accessibilityHidden(true)
        } else if let systemIcon = category.systemIcon {
            Image(systemName: systemIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BrandColors.magenta)
                .accessibilityHidden(true)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 16) {
            ChromeGlyph(systemName: "person.crop.circle.fill",
                        selected: youTubeAccount.isConnected, size: 36, hit: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(youTubeAccount.account?.channel?.title
                     ?? tr("Not signed in", "未登录"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                Text(youTubeAccount.isConnected
                     ? tr("YouTube connected", "已连接 YouTube")
                     : tr("Connect YouTube in Settings", "在设置中连接 YouTube"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            if youTubeAccount.isConnected {
                Button(tr("Sign Out", "退出登录")) { youTubeAccount.disconnect() }
                    .buttonStyle(.bordered)
            } else {
                Button(tr("Connect", "连接")) {
                    selectedCategory = .youtube
                    showingDetail = true
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .help(tr("Open YouTube connection settings", "打开 YouTube 连接设置"))
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private func handleEscape() {
        if showingDetail {
            showingDetail = false
        } else {
            close()
        }
    }

    private func close() {
        isPresented = false
    }
}

/// About settings page: logo + version + GitHub link + compliance notice.
/// Update checking moved to the dedicated "Updates" category (UpdatesSettingsView).
struct AboutSettingsView: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Section(tr("About", "关于")) {
            VStack(alignment: .leading, spacing: 16) {
                // Logo + version
                HStack(spacing: 16) {
                    Group {
                        let url = Bundle.main.url(forResource: "logo", withExtension: "png")
                            ?? Bundle.module.url(forResource: "logo", withExtension: "png")
                        if let url, let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .cornerRadius(12)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(BrandColors.magenta)
                                .frame(width: 56, height: 56)
                                .overlay(Text("M").font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(BrandColors.textPrimary))
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Muses").font(BrandFont.muses(30))
                            .foregroundStyle(BrandColors.textPrimary)
                        Text("\(tr("Version", "版本")) \(appVersion)")
                            .font(.caption).foregroundStyle(BrandColors.textSecondary)
                    }
                    Spacer()
                }

                // GitHub link
                Button {
                    if let url = URL(string: "https://github.com/xiaotwu/noname123") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(tr("GitHub Project", "GitHub 项目"), systemImage: "link")
                }
                .buttonStyle(.bordered)

                Divider()

                Section(tr("Disclaimer", "合规声明")) {
                    Text(tr("This software is for personal use only, not distributed on the App Store. YouTube content is subject to YouTube's Terms of Service; downloading must comply with applicable local laws.",
                            "本软件仅供个人使用, 不在 App Store 分发。YouTube 内容受 YouTube 服务条款约束, 下载行为需遵守当地法律法规。"))
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineSpacing(3)
                    Text(tr("Tech stack: Swift + SwiftUI + AVAudioEngine + SwiftData + yt-dlp",
                            "技术栈: Swift + SwiftUI + AVAudioEngine + SwiftData + yt-dlp"))
                        .font(.caption2)
                        .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
                }
            }
            .padding(.vertical, 8)
        }
    }
}
