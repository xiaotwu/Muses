import SwiftUI

/// 设置弹窗(从用户控件弹出,玻璃特效背景)。
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showEQEditor = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(tr("Settings", "设置"))
                    .font(.headline)
                    .foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView {
                Form {
                    ScanRootsSettingsView()
                    AudioQualitySettingsView()
                    PlaybackSettingsView()
                    GPUSettingsView()
                    YouTubeSettingsView()
                    LyricsSettingsView()

                    Section(tr("Equalizer", "均衡器")) {
                        Button { showEQEditor = true } label: {
                            Label(tr("Open EQ Editor", "打开 EQ 编辑器"), systemImage: "slider.vertical.3")
                        }
                        .buttonStyle(.bordered)
                        .tint(BrandColors.cyan)
                    }

                    ThemeSettingsView()
                    NotificationsSettingsView()
                    UpdatesSettingsView()
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.ultraThinMaterial)
        .frame(width: 600)
        .frame(maxHeight: 640)
        .sheet(isPresented: $showEQEditor) {
            EQEditorView()
        }
    }
}

/// 关于弹窗(从用户控件弹出,玻璃特效背景)。
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                // Logo
                Group {
                    if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .cornerRadius(12)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [BrandColors.magenta, BrandColors.cyan],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 64, height: 64)
                            .overlay(Text("M").font(.system(size: 36, weight: .bold))
                                .foregroundStyle(BrandColors.textPrimary))
                    }
                }

                VStack(alignment: .leading) {
                    Text("Muses").font(.title2).fontWeight(.bold)
                        .foregroundStyle(BrandColors.textPrimary)
                    Text(tr("Version ", "版本 ") + appVersion)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
            }

            Text(tr("Muses is a macOS music player inspired by TIDAL, supporting local music and YouTube playlists.",
                    "Muses 是一款受 TIDAL 启发的 macOS 音乐播放器, 支持本地音乐与 YouTube 歌单。"))
                .font(.callout)
                .foregroundStyle(BrandColors.textPrimary)
                .lineSpacing(4)

            Text(tr("Disclaimer: This software is for personal use only, not distributed on the App Store. YouTube content is subject to YouTube's Terms of Service.",
                    "合规声明: 本软件仅供个人使用, 不在 App Store 分发。YouTube 内容受 YouTube 服务条款约束, 下载行为需遵守当地法律法规。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
                .lineSpacing(3)

            Text(tr("Tech stack: Swift + SwiftUI + AVAudioEngine + SwiftData + yt-dlp",
                    "技术栈: Swift + SwiftUI + AVAudioEngine + SwiftData + yt-dlp"))
                .font(.caption2)
                .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .frame(width: 440)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}