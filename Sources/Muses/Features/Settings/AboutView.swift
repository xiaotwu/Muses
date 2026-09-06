import SwiftUI

/// About page: version + logo + compliance notice.
struct AboutView: View {
    var body: some View {
        Section(tr("About", "关于")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    // Logo (loaded from the bundle, falling back to a white rounded placeholder)
                    Group {
                        let url = Bundle.main.url(forResource: "logo", withExtension: "png")
                            ?? Bundle.module.url(forResource: "logo", withExtension: "png")
                        if let url, let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .cornerRadius(12)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(BrandColors.magenta)
                                .frame(width: 64, height: 64)
                                .overlay(Text("M").font(.system(size: 36, weight: .bold))
                                    .foregroundStyle(BrandColors.textPrimary))
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Muses").font(BrandFont.muses(30))
                            .foregroundStyle(BrandColors.textPrimary)
                        Text("\(tr("Version", "版本")) \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }

                Divider()

                Text(tr("Muses is a native macOS, YouTube-native music player shaped by Apple Music's editorial hierarchy and Liquid Glass chrome.",
                        "Muses 是一款原生 macOS、以 YouTube 为核心的音乐播放器，采用 Apple Music 式内容层级与 Liquid Glass 界面。"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineSpacing(4)

                Text(tr("Notice: This software is for personal use only and is not distributed on the App Store. YouTube content is subject to YouTube's Terms of Service; downloading must comply with applicable local laws.", "合规声明: 本软件仅供个人使用, 不在 App Store 分发。YouTube 内容受 YouTube 服务条款约束, 下载行为需遵守当地法律法规。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineSpacing(3)
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
