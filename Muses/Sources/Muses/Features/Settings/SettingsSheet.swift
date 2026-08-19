import SwiftUI
import AppKit

/// 设置类别枚举。
enum SettingsCategory: String, Hashable, CaseIterable {
    case general, playback, audioQuality, library, appearance, youtube, lyrics, desktop, updates, about

    var label: String {
        switch self {
        case .general:      return tr("General", "通用")
        case .playback:     return tr("Playback", "播放")
        case .audioQuality: return tr("Audio Quality", "音质")
        case .library:      return tr("Library", "资料库")
        case .appearance:   return tr("Appearance", "外观")
        case .youtube:      return tr("YouTube", "YouTube")
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
        case .audioQuality: return "waveform"
        case .library:      return "folder"
        case .appearance:   return "paintbrush"
        case .youtube:      return "play.rectangle"
        case .lyrics:       return "text.alignleft"
        case .desktop:      return "menubar.rectangle"
        case .updates:      return "arrow.triangle.2.circlepath"
        case .about:        return "info.circle"
        }
    }
}

/// 设置弹窗:左侧分类 + 右侧内容(macOS 系统设置风格)。
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: SettingsCategory
    @State private var showEQEditor = false

    init(initialCategory: SettingsCategory? = nil) {
        _selectedCategory = State(initialValue: initialCategory ?? .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧:类别列表
            List(selection: $selectedCategory) {
                ForEach(SettingsCategory.allCases, id: \.self) { cat in
                    Label(cat.label, systemImage: cat.icon)
                        .tag(cat)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 180)

            Divider()

            // 右侧:选中类别的内容
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
                        Section(tr("Equalizer", "均衡器")) {
                            Button { showEQEditor = true } label: {
                                Label(tr("Open EQ Editor", "打开 EQ 编辑器"), systemImage: "slider.vertical.3")
                            }
                            .buttonStyle(.bordered)
                            .tint(BrandColors.magenta)
                        }
                    case .audioQuality:
                        AudioQualitySettingsView()
                    case .library:
                        ScanRootsSettingsView()
                    case .appearance:
                        ThemeSettingsView()
                    case .youtube:
                        YouTubeSettingsView()
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
        }
        .background(.ultraThinMaterial)
        .frame(width: 680, height: 520)
        .sheet(isPresented: $showEQEditor) {
            EQEditorView()
        }
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