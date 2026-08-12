import Foundation

/// i18n 基础设施:基于系统语言自动选择英语或中文。
///
/// 使用 `tr(en, zh)` 函数替代硬编码字符串,无需 .strings 文件,
/// 完美兼容 SPM(无 resource bundling 问题)。
///
/// 用法:
/// ```swift
/// Text(tr("Home", "首页"))
/// Label(tr("Albums", "专辑"), systemImage: "square.stack")
/// .navigationTitle(tr("Albums", "专辑"))
/// Button(tr("Play", "播放")) { ... }
/// ```
enum L10n {
    /// 检测当前系统语言是否为中文(zh-Hans / zh-Hant / zh-HK 等)。
    static var isChinese: Bool {
        Locale.current.language.languageCode?.identifier.hasPrefix("zh") ?? false
    }
}

/// 双语字符串:根据系统语言自动选择英语或中文。
/// - Parameters:
///   - en: 英语文案
///   - zh: 中文文案
/// - Returns: 当前语言对应的字符串
func tr(_ en: String, _ zh: String) -> String {
    L10n.isChinese ? zh : en
}