import SwiftUI

/// Muses 模块资源定位(供测试访问 SPM `.copy("Resources")` 拷入的文件)。
enum MusesResources {
    /// Info.plist 模板 URL(打包脚本注入 .app 的 Contents/Info.plist)。
    static let infoPlistURL = Bundle.module.url(forResource: "Info", withExtension: "plist")
    /// entitlements 模板 URL(codesign --entitlements 用)。
    static let entitlementsURL = Bundle.module.url(forResource: "Muses", withExtension: "entitlements")
    /// MonteCarlo 字体 URL(App 启动时注册为可用字体)。
    static let monteCarloFontURL = Bundle.module.url(forResource: "MonteCarlo", withExtension: "ttf")
}

/// 更新设置:GitHub Release 自动检查开关 + 立即检查 + 版本状态展示。
///
/// 通过 `UpdateService` 查询 GitHub Releases API(`repos/xiaotwu/noname123/releases/latest`),
/// 与当前 `CFBundleShortVersionString` 比较。个人使用,不做自动安装:有新版本时
/// 用户点击"下载"跳转到 GitHub Release 页。
struct UpdatesSettingsView: View {
    @AppStorage(PrefKey.checkForUpdates) private var checkAutomatically: Bool = true
    @Environment(UpdateService.self) private var updater

    var body: some View {
        Section(tr("Updates", "更新")) {
            Toggle(tr("Check for Updates Automatically", "自动检查更新"), isOn: $checkAutomatically)

            HStack {
                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    Label(tr("Check for Updates Now", "立即检查更新"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(BrandColors.magenta)
                .disabled(updater.isChecking)

                if updater.isChecking {
                    ProgressView().controlSize(.small)
                }
            }

            statusView
        }
    }

    /// 版本状态行:当前版本 / 最新版本 / 是否有更新 / 下载按钮 / 错误。
    @ViewBuilder
    private var statusView: some View {
        if let err = updater.lastError {
            Text("\(tr("Last check failed:", "上次检查失败:")) \(err)")
                .font(.caption).foregroundStyle(.orange)
        }
        HStack(spacing: 8) {
            Text("\(tr("Current", "当前")) \(updater.currentVersion)")
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
            if let latest = updater.latestVersion {
                Text("·").foregroundStyle(BrandColors.textSecondary)
                Text("\(tr("Latest", "最新")) \(latest)")
                    .font(.caption)
                    .foregroundStyle(updater.hasUpdate ? BrandColors.magenta
                                     : BrandColors.textSecondary)
            }
        }
        if updater.hasUpdate {
            Button {
                updater.openReleasePage()
            } label: {
                Label(tr("Download Update", "下载更新"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
        }
        Text(tr("Checks for updates via GitHub Releases API. New versions open the GitHub release page for manual download.",
                "通过 GitHub Releases API 检查更新。发现新版本时打开 GitHub Release 页手动下载。"))
            .font(.caption2)
            .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
    }
}