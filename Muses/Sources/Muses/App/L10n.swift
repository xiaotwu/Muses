import Foundation

/// i18n 基础设施:基于用户语言偏好或系统语言自动选择英语或中文。
///
/// 使用 `tr(en, zh)` 函数替代硬编码字符串,无需 .strings 文件,
/// 完美兼容 SPM(无 resource bundling 问题)。
///
/// 语言优先级:`@AppStorage(PrefKey.language)` > 系统语言
///
/// 用法:
/// ```swift
/// Text(tr("Home", "首页"))
/// Label(tr("Albums", "专辑"), systemImage: "square.stack")
/// .navigationTitle(tr("Albums", "专辑"))
/// Button(tr("Play", "播放")) { ... }
/// ```
enum L10n {
    /// 检测当前应使用中文:优先读用户语言偏好,回退系统语言。
    static var isChinese: Bool {
        let pref = UserDefaults.standard.string(forKey: PrefKey.language) ?? "system"
        if pref == "system" {
            return Locale.current.language.languageCode?.identifier.hasPrefix("zh") ?? false
        }
        return pref == "zh"
    }
}

/// 双语字符串:根据当前语言自动选择英语或中文。
/// - Parameters:
///   - en: 英语文案
///   - zh: 中文文案
/// - Returns: 当前语言对应的字符串
func tr(_ en: String, _ zh: String) -> String {
    L10n.isChinese ? zh : en
}