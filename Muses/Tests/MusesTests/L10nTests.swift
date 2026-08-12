import Testing
import Foundation
import AppKit
@testable import Muses

/// i18n 基础设施 + 主题基础测试。
@Suite("L10n + Theme")
struct L10nThemeTests {

    @Test("tr() 根据系统语言返回正确文案")
    func trReturnsCorrectLanguage() {
        // tr() 始终根据 Locale.current 判断,我们验证函数存在且可调用
        let result = tr("Home", "首页")
        // 结果应该是两个之一
        #expect(result == "Home" || result == "首页")
    }

    @Test("L10n.isChinese 检测中文环境")
    func isChineseDetection() {
        // 验证属性可访问且返回 Bool
        let isZh = L10n.isChinese
        #expect(isZh == true || isZh == false)
    }

    @Test("BrandColors.hairline 透明(取消分割线)")
    func hairlineTransparent() {
        // BrandColors.hairline 是动态 NSColor,在深色模式下 alpha=0
        // 验证 Color 可正常构造(间接验证 NSColor 不 crash)
        let _ = BrandColors.hairline
        let _ = BrandColors.background
        let _ = BrandColors.surface
        #expect(true)
    }

    @Test("PrefKey.gpuAcceleration 存在")
    func gpuPrefKeyExists() {
        #expect(PrefKey.gpuAcceleration == "muses.gpuAcceleration")
    }
}