import SwiftUI
import AppKit

/// Guided writer for `~/.config/yt-dlp/config`. yt-dlp reads this itself,
/// so the app no longer injects `--cookies-from-browser`.
struct YTDlpConfigWizard: View {
    @State private var browser: Browser = .safari
    @State private var status: String?

    enum Browser: String, CaseIterable {
        case safari, chrome, firefox, none
        var label: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Chrome"
            case .firefox: return "Firefox"
            case .none: return tr("None", "无")
            }
        }
    }

    var body: some View {
        Section(tr("yt-dlp setup", "yt-dlp 配置")) {
            Picker(tr("Cookies", "Cookies"), selection: $browser) {
                ForEach(Browser.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Button(tr("Write yt-dlp config…", "写入 yt-dlp 配置…")) {
                status = writeConfig()
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.magenta)
            if let status {
                Text(status).font(.caption).foregroundStyle(BrandColors.textSecondary)
            }
        }
    }

    private func writeConfig() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/yt-dlp", isDirectory: true)
        let file = dir.appendingPathComponent("config")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = [
                "# Written by Muses",
                "--geo-bypass"
            ]
            let cookieSource: YTCookieSource
            switch browser {
            case .safari:
                lines.append("--cookies-from-browser safari")
                cookieSource = .safari
            case .chrome:
                lines.append("--cookies-from-browser chrome")
                cookieSource = .chrome
            case .firefox:
                lines.append("--cookies-from-browser firefox")
                cookieSource = .firefox
            case .none:
                cookieSource = .none
            }
            try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(cookieSource.rawValue, forKey: PrefKey.ytCookieSource)
            return tr("Wrote \(file.path)", "已写入 \(file.path)")
        } catch {
            return error.localizedDescription
        }
    }
}
