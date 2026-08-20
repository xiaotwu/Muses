import SwiftUI
import AppKit

/// 设置类别枚举。
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

    var icon: String {
        switch self {
        case .general:      return "gear"
        case .playback:     return "play.circle"
        case .audioQuality: return "sparkles.tv"
        case .appearance:   return "paintbrush"
        case .youtube:      return "play.rectangle.fill"
        case .lyrics:       return "text.alignleft"
        case .desktop:      return "menubar.rectangle"
        case .updates:      return "arrow.triangle.2.circlepath"
        case .about:        return "info.circle"
        }
    }
}

/// Apple Music–style Account page in the main content slot.
struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @State private var selectedCategory: SettingsCategory
    @State private var showingDetail: Bool
    @State private var escapeMonitor: Any?
    @Environment(YouTubeAccountService.self) private var youTubeAccount

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
                Spacer()
                ChromeIconButton(
                    systemName: "xmark",
                    help: tr("Close", "关闭"),
                    accessibility: tr("Close Settings", "关闭设置")
                ) { close() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if showingDetail {
                Text(selectedCategory.label)
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                ScrollView {
                    Form {
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
                            YouTubeSettingsView()
                            YTDlpConfigWizard()
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
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(tr("Settings", "设置"))
                            .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                            .foregroundStyle(BrandColors.textPrimary)
                        accountHeader
                        VStack(spacing: 0) {
                            ForEach(SettingsCategory.allCases, id: \.self) { cat in
                                Button {
                                    selectedCategory = cat
                                    showingDetail = true
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: cat.icon)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(BrandColors.magenta)
                                            .frame(width: 28, height: 28)
                                        Text(cat.label)
                                            .foregroundStyle(BrandColors.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(BrandColors.textSecondary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                if cat != SettingsCategory.allCases.last {
                                    Divider().opacity(0.15)
                                }
                            }
                        }
                        .background(BrandColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 100)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
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
                    Task { await youTubeAccount.connect() }
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
            }
        }
        .padding(16)
        .background(BrandColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// 关于设置页: logo + 版本 + GitHub 链接 + 合规声明。
/// 更新检查已移至独立的 "更新" 设置类别(`UpdatesSettingsView`)。
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
                // Logo + 版本
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

                // GitHub 链接
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