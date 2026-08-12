import SwiftUI

/// yt-dlp 桥接器的环境注入键。
private struct YTDlpBridgeEnvironmentKey: EnvironmentKey {
    static let defaultValue: YTDlpBridge? = nil
}

extension EnvironmentValues {
    /// `YTDlpBridge`(由 `MusesApp` 注入);缺省 nil 用于预览/未注入场景。
    var ytDlpBridge: YTDlpBridge? {
        get { self[YTDlpBridgeEnvironmentKey.self] }
        set { self[YTDlpBridgeEnvironmentKey.self] = newValue }
    }
}

/// YouTube / yt-dlp 设置:二进制路径(只读)、版本检查、登录态占位。
///
/// 登录态与 YT Data API 写同步留待 Phase 4 实装;本地附加永不调 YT 写 API。
struct YouTubeSettingsView: View {
    @Environment(\.ytDlpBridge) private var bridge

    @State private var binaryPath: String?
    @State private var versionString: String?
    @State private var checkingVersion = false

    var body: some View {
        Section("YouTube / yt-dlp") {
            row("yt-dlp 路径", value: binaryPath ?? "未找到(将用 PATH 中的 yt-dlp 或随包二进制)")

            HStack {
                Text("yt-dlp 版本").foregroundStyle(BrandColors.textSecondary)
                Spacer()
                if let versionString {
                    Text(versionString).foregroundStyle(.white)
                } else if checkingVersion {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").foregroundStyle(BrandColors.textSecondary)
                }
            }

            Button {
                Task { await checkVersion() }
            } label: {
                Label("检查 yt-dlp 版本", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.cyan)
            .disabled(bridge == nil || checkingVersion)

            Text("个人使用:yt-dlp 仅用于播放/导入,不分发音频;YouTube 内容受 YouTube ToS 约束。登录态与写同步待 Phase 4。")
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .task {
            if let bridge { binaryPath = await bridge.locateBinary() }
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private func checkVersion() async {
        guard let bridge else { return }
        checkingVersion = true
        defer { checkingVersion = false }
        versionString = await bridge.version()
        // 版本检查时顺带刷新路径。
        if let p = await bridge.locateBinary() { binaryPath = p }
    }
}