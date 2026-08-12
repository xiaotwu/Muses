import SwiftUI

/// 关于页: 版本号 + logo + 合规声明。
struct AboutView: View {
    var body: some View {
        Section("关于") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    // Logo 占位
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(colors: [BrandColors.magenta, BrandColors.cyan],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 64, height: 64)
                        .overlay(Text("M").font(.system(size: 36, weight: .bold))
                            .foregroundStyle(BrandColors.textPrimary))
                    VStack(alignment: .leading) {
                        Text("Muses").font(.title2).fontWeight(.bold)
                            .foregroundStyle(BrandColors.textPrimary)
                        Text("版本 \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }

                Divider()

                Text("Muses 是一款受 TIDAL 启发的 macOS 音乐播放器, 支持本地音乐与 YouTube 歌单。")
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineSpacing(4)

                Text("合规声明: 本软件仅供个人使用, 不在 App Store 分发。YouTube 内容受 YouTube 服务条款约束, 下载行为需遵守当地法律法规。")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineSpacing(3)

                Text("技术栈: Swift + SwiftUI + AVAudioEngine + SwiftData + yt-dlp")
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
            }
            .padding(.vertical, 8)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}