import SwiftUI

/// Muses module resource locator (lets tests reach files copied in via SPM `.copy("Resources")`).
enum MusesResources {
    /// Info.plist template URL (packaging injects it into .app/Contents/Info.plist).
    static let infoPlistURL = Bundle.module.url(forResource: "Info", withExtension: "plist")
    /// Entitlements template URL (used by codesign --entitlements).
    static let entitlementsURL = Bundle.module.url(forResource: "Muses", withExtension: "entitlements")
    /// MonteCarlo font URL (registered as an available font at app launch).
    static let monteCarloFontURL = Bundle.module.url(forResource: "MonteCarlo", withExtension: "ttf")
}

/// Update settings: GitHub Release auto-check switch + check now + version status.
///
/// `UpdateService` queries the GitHub Releases API (repos/xiaotwu/noname123/releases/latest)
/// and compares it with `CFBundleShortVersionString`. Personal use only — nothing auto-installs:
/// when a new version exists, "Download" opens the GitHub Release page.
struct UpdatesSettingsView: View {
    @AppStorage(PrefKey.checkForUpdates) private var checkAutomatically: Bool = true
    @Environment(UpdateService.self) private var updater

    var body: some View {
        Section(tr("Updates", "更新")) {
            Toggle(tr("Check for Updates Automatically", "自动检查更新"), isOn: $checkAutomatically)
                .tint(BrandColors.magenta)

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

    /// Version status row: current version / latest version / update availability / download button / error.
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
    }
}