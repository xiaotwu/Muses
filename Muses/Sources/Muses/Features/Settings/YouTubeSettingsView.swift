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

/// YouTube / yt-dlp 设置:二进制路径(只读)、版本检查、登录/cookie。
///
/// cookie 来源支持浏览器(Safari/Chrome/Firefox)或 cookie 文件,
/// 让 yt-dlp 访问登录态内容(年龄限制/私有歌单等)。
struct YouTubeSettingsView: View {
    @Environment(\.ytDlpBridge) private var bridge

    @AppStorage(PrefKey.ytCookieSource) private var cookieSourceRaw: String = YTCookieSource.none.rawValue
    @AppStorage(PrefKey.ytCookiePath) private var cookiePath: String = ""

    @State private var binaryPath: String?
    @State private var versionString: String?
    @State private var checkingVersion = false
    @State private var showFilePicker = false

    private var cookieSource: YTCookieSource {
        YTCookieSource(rawValue: cookieSourceRaw) ?? .none
    }

    var body: some View {
        Section("YouTube / yt-dlp") {
            row("yt-dlp 路径", value: binaryPath ?? "未找到(将用 PATH 中的 yt-dlp 或随包二进制)")

            HStack {
                Text("yt-dlp 版本").foregroundStyle(BrandColors.textSecondary)
                Spacer()
                if let versionString {
                    Text(versionString).foregroundStyle(BrandColors.textPrimary)
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
        }

        Section("登录 / Cookie") {
            Picker("Cookie 来源", selection: $cookieSourceRaw) {
                ForEach(YTCookieSource.allCases, id: \.rawValue) { src in
                    Text(src.displayName).tag(src.rawValue)
                }
            }

            if cookieSource == .file {
                HStack {
                    Text("Cookie 文件").foregroundStyle(BrandColors.textSecondary)
                    Spacer()
                    Text(cookiePath.isEmpty ? "未选择" : cookiePath)
                        .foregroundStyle(BrandColors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(cookiePath)
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("选择 Cookie 文件…", systemImage: "doc")
                }
                .buttonStyle(.bordered)
            }

            Text(cookieHelpText)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .task {
            if let bridge { binaryPath = await bridge.locateBinary() }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.text],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                cookiePath = url.path
            }
        }
    }

    private var cookieHelpText: String {
        switch cookieSource {
        case .none:
            return "不使用 cookie。公开内容可直接播放/导入;登录态内容(年龄限制/私有歌单)无法访问。"
        case .safari:
            return "从 Safari 读取 cookie。需在 系统设置 → 隐私与安全性 → 完全磁盘访问 中授权 Muses。"
        case .chrome:
            return "从 Chrome 读取 cookie。Chrome 需已登录 YouTube。"
        case .firefox:
            return "从 Firefox 读取 cookie。Firefox 需已登录 YouTube。"
        case .file:
            return "使用 Netscape 格式的 cookie 文件(可用浏览器扩展导出)。适合跨浏览器或无 GUI 场景。"
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(BrandColors.textPrimary)
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