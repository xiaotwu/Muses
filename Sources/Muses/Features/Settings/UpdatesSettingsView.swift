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
            Toggle(tr("Check for Updates Automatically", "自动检查更新"),
                   isOn: Binding(get: { updater.automaticallyChecks },
                                 set: { updater.setAutomaticallyChecks($0) }))
                .tint(BrandColors.accent)
                .disabled(!updater.isConfigured)
            Toggle(tr("Download and Install Updates Automatically", "自动下载并安装更新"),
                   isOn: Binding(get: { updater.automaticallyInstalls },
                                 set: { updater.setAutomaticallyInstalls($0) }))
                .tint(BrandColors.accent)
                .disabled(!updater.isConfigured)
            Text(tr("Updates restart Muses after saving playback state. Playback, video, imports, and synchronization postpone automatic restarts.",
                    "更新会在保存播放状态后重启 Muses。播放、视频、导入和同步期间将推迟自动重启。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
            HStack {
                Button {
                    Task { await updater.checkForUpdates() }
                } label: {
                    Label(tr("Check for Updates Now", "立即检查更新"), systemImage: "arrow.triangle.2.circlepath")
                }
                .musesAction()
                .disabled(!updater.canCheck)
                if updater.isChecking { ProgressView().controlSize(.small) }
            }
            statusView
        } header: {
            Text(tr("Updates", "更新")).font(.headline.weight(.semibold))
        }
    }

    @ViewBuilder private var statusView: some View {
        HStack(spacing: 8) {
            Text("\(tr("Current", "当前")) \(updater.currentVersion)")
            if let latest = updater.latestVersion {
                Text("·")
                Text("\(tr("Latest", "最新")) \(latest)")
            }
        }
        .font(.caption).foregroundStyle(BrandColors.textSecondary)
        if !updater.isConfigured {
            Text(tr("Automatic updates are not configured in this build.", "此构建尚未配置自动更新。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }
        if let error = updater.lastError {
            Text(error).font(.caption).foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if !statusText.isEmpty {
            Text(statusText).font(.caption).accessibilityLabel(statusText)
        }
        if updater.phase == .downloading {
            if let progress = updater.downloadProgress {
                ProgressView(value: progress)
                    .accessibilityValue(Text("\(Int(progress * 100))%"))
            } else { ProgressView().controlSize(.small) }
        }
        if updater.canDownload {
            Button { updater.downloadUpdate() } label: {
                Label(tr("Download Update", "下载更新"), systemImage: "arrow.down.circle")
            }
            .musesAction(prominent: true)
        }
        if updater.canCancelDownload {
            Button(tr("Cancel", "取消")) { updater.cancelDownload() }.musesAction()
        }
        if updater.canInstall {
            HStack {
                Button(tr("Update and Restart", "更新并重启")) { updater.installNow() }
                    .musesAction(prominent: true)
                Button(tr("Later", "稍后")) { updater.deferRestart() }.musesAction()
            }
        }
        Button(tr("Release Notes", "版本说明")) { updater.openReleasePage() }
            .musesAction()
    }

    private var statusText: String {
        if let seconds = updater.countdown {
            return tr("Restarting in \(seconds) seconds", "\(seconds) 秒后重启")
        }
        switch updater.phase {
        case .idle: return ""
        case .checking: return tr("Checking for updates…", "正在检查更新…")
        case .available: return tr("An update is available.", "有可用更新。")
        case .downloading: return tr("Downloading update…", "正在下载更新…")
        case .verifying: return tr("Verifying and preparing update…", "正在验证并准备更新…")
        case .ready: return tr("Ready to update. Automatic restart waits until playback and other operations are idle.",
                               "更新已就绪。自动重启将等待播放及其他操作空闲。")
        case .installing: return tr("Installing and restarting…", "正在安装并重启…")
        case .upToDate: return updater.lastError == nil ? tr("Muses is up to date.", "Muses 已是最新版本。") : ""
        case .failed: return tr("Update could not be completed.", "更新未能完成。")
        }
    }
}
