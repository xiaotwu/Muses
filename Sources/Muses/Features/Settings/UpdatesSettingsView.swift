import SwiftUI

/// Muses module resource locator (lets tests reach files copied in via SPM `.copy("Resources")`).
enum MusesResources {
    /// Info.plist template URL (packaging injects it into .app/Contents/Info.plist).
    static let infoPlistURL = Bundle.module.url(forResource: "Info", withExtension: "plist", subdirectory: "Resources")
    /// Entitlements template URL (used by codesign --entitlements).
    static let entitlementsURL = Bundle.module.url(forResource: "Muses", withExtension: "entitlements", subdirectory: "Resources")
    /// Bundled brand font URL (registered at application launch).
    static let islandMomentsFontURL = Bundle.module.url(forResource: "IslandMoments-Regular", withExtension: "ttf", subdirectory: "Resources")
}

/// Update preferences and progress share the app-lifetime update facade.
struct UpdatesSettingsView: View {
    @Environment(UpdateService.self) private var updater

    var body: some View {
        Section {
            LabeledContent(tr("Version status", "版本状态")) {
                HStack(spacing: 8) {
                    if updater.isChecking { ProgressView().controlSize(.small) }
                    else { SettingsStatus(title: summaryText, symbol: statusSymbol) }
                    if let error = updater.lastError {
                        SettingsInfoButton(title: tr("Update details", "更新详情"), message: error)
                    }
                    SettingsIconButton(title: tr("Check for updates", "检查更新"), symbol: "arrow.clockwise") {
                        Task { await updater.checkForUpdates() }
                    }.disabled(!updater.canCheck)
                }
            }
            Toggle(tr("Automatic checks", "自动检查"),
                   isOn: Binding(get: { updater.automaticallyChecks },
                                 set: { updater.setAutomaticallyChecks($0) }))
                .disabled(!updater.isConfigured)
            SettingsExplainedToggle(title: tr("Automatic installation", "自动安装"),
                isOn: Binding(get: { updater.automaticallyInstalls },
                              set: { updater.setAutomaticallyInstalls($0) }),
                information: tr("Updates restart Muses after saving playback state. Playback, video, imports, and synchronization postpone automatic restarts.",
                                "空闲时保存播放状态后更新并重启。播放、视频、导入和同步期间会等待。"),
                enabled: updater.isConfigured)
            statusView
        } header: { Text(tr("Updates", "更新")).font(MusesTypography.headline) }
    }

    @ViewBuilder private var statusView: some View {
        if let latest = updater.latestVersion, latest != updater.currentVersion {
            LabeledContent(tr("Latest version", "最新版本"), value: latest)
                .font(MusesTypography.caption)
        }
        if let countdown = updater.countdown {
            Text(tr("Restarting in \(countdown) seconds", "\(countdown) 秒后重启"))
                .font(MusesTypography.caption)
        }
        if updater.phase == .ready {
            SettingsStatus(title: tr("Installs when playback and sync are idle", "播放与同步空闲时安装"), symbol: "clock")
        }
        if updater.phase == .downloading {
            if let progress = updater.downloadProgress {
                ProgressView(value: progress)
                    .accessibilityValue(Text("\(Int(progress * 100))%"))
            } else { ProgressView().controlSize(.small) }
        }
        if updater.canDownload || updater.canCancelDownload || updater.canInstall {
            HStack(spacing: 8) {
                Spacer()
                if updater.canDownload {
                    Button { updater.downloadUpdate() } label: {
                        Label(tr("Download", "下载更新"), systemImage: "arrow.down.circle")
                    }.settingsAction(prominent: true)
                }
                if updater.canCancelDownload {
                    Button(tr("Cancel", "取消")) { updater.cancelDownload() }.settingsAction()
                }
                if updater.canInstall {
                    Button(tr("Update and restart", "更新并重启")) { updater.installNow() }
                        .settingsAction(prominent: true)
                    Button(tr("Later", "稍后")) { updater.deferRestart() }.settingsAction()
                }
            }
        }
    }

    private var summaryText: String {
        guard updater.isConfigured else { return tr("Not configured", "未配置") }
        switch updater.phase {
        case .idle: return tr("Ready to check", "可检查更新")
        case .checking: return tr("Checking…", "正在检查…")
        case .available: return tr("Update available", "有新版本")
        case .downloading: return tr("Downloading…", "正在下载…")
        case .verifying: return tr("Verifying…", "正在验证…")
        case .ready: return tr("Ready to install", "可安装")
        case .installing: return tr("Installing…", "正在安装…")
        case .upToDate: return tr("Up to date", "已是最新")
        case .failed: return tr("Update unavailable", "更新暂不可用")
        }
    }

    private var statusSymbol: String {
        switch updater.phase {
        case .failed: "exclamationmark.triangle"
        case .ready, .available: "arrow.down.circle"
        case .upToDate: "checkmark.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

}
