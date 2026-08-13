import SwiftUI
import Sparkle

/// Muses 模块资源定位(供测试访问 SPM `.copy("Resources")` 拷入的文件)。
enum MusesResources {
    /// appcast.xml 模板 URL(随 Muses 模块 bundle 分发)。
    static let appcastURL = Bundle.module.url(forResource: "appcast", withExtension: "xml")
    /// Info.plist 模板 URL(打包脚本注入 .app 的 Contents/Info.plist)。
    static let infoPlistURL = Bundle.module.url(forResource: "Info", withExtension: "plist")
    /// entitlements 模板 URL(codesign --entitlements 用)。
    static let entitlementsURL = Bundle.module.url(forResource: "Muses", withExtension: "entitlements")
}

/// Sparkle 自动更新的环境注入键。
private struct UpdaterEnvironmentKey: EnvironmentKey {
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    /// Sparkle `SPUUpdater`(由 `MusesApp` 从 `SPUStandardUpdaterController.updater` 注入)。
    /// 缺省 `nil`:开发/SPM 构建未配置 `SUFeedURL` 时控制器不 startUpdater,此处为 nil。
    var updater: SPUUpdater? {
        get { self[UpdaterEnvironmentKey.self] }
        set { self[UpdaterEnvironmentKey.self] = newValue }
    }
}

/// 更新设置:Sparkle 自动检查开关 + 立即检查按钮。
///
/// 注:`SUFeedURL` / `SUPublicEDKey` 需在 .app 的 Info.plist 注入
/// (详见 `Resources/appcast.xml`);SPM executable 缺键时按钮禁用。
struct UpdatesSettingsView: View {
    @AppStorage(PrefKey.checkForUpdates) private var checkAutomatically: Bool = true
    @Environment(\.updater) private var updater

    /// 是否已配置发布所需 Info.plist 键(决定 UI 是否可用)。
    private var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    var body: some View {
        Section(tr("Updates", "更新")) {
            Toggle(tr("Check for Updates Automatically", "自动检查更新"), isOn: $checkAutomatically)
                .disabled(updater == nil)
                .onChange(of: checkAutomatically) {
                    updater?.automaticallyChecksForUpdates = checkAutomatically
                }

            Button {
                updater?.checkForUpdates()
            } label: {
                Label(tr("Check for Updates Now", "立即检查更新"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .tint(BrandColors.cyan)
            .disabled(updater == nil)

            if isConfigured {
                Text(tr("Checks and installs updates via Sparkle; on release, appcast is verified with an EdDSA signature.", "通过 Sparkle 检查并安装更新;发布时用 EdDSA 签名 appcast 验证。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            } else {
                Text(tr("Automatic updates pending configuration: when packaging the .app, inject SUFeedURL and SUPublicEDKey into Info.plist.", "自动更新待配置:打包 .app 时需在 Info.plist 注入 SUFeedURL 与 SUPublicEDKey。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .onAppear {
            // 把 Sparkle 的检查策略与偏好同步(默认每日检查)。
            updater?.automaticallyChecksForUpdates = checkAutomatically
            updater?.updateCheckInterval = 86_400
        }
    }
}