import Foundation
import CoreText
import SwiftUI

/// 应用字体注册:把随包资源中的自定义字体注册到进程内,使其可通过
/// `NSFont(name:)` / SwiftUI `.custom(_:size:)` 使用。
@MainActor
enum FontLoader {
    private static var didRegister = false

    /// 注册 MonteCarlo 字体(品牌字标用)。重复调用安全(仅注册一次)。
    /// 注册失败仅记录日志,不阻断启动 —— `.custom("MonteCarlo", ...)` 会静默
    /// 回退到系统字体。
    static func registerMonteCarlo() {
        guard !didRegister else { return }
        didRegister = true
        guard let url = MusesResources.monteCarloFontURL else {
            AppLog.for("FontLoader").warning("MonteCarlo.ttf 资源未找到,字标回退系统字体")
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok {
            let desc = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            AppLog.for("FontLoader").warning("MonteCarlo 注册失败:\(desc)")
        }
    }
}

/// 品牌字标字体(MonteCarlo,优雅手写体)。用于 "Muses" wordmark。
/// 字体未注册时 `.custom` 静默回退到系统字体,故无需额外降级逻辑。
enum BrandFont {
    /// Muses 品牌字标字体(MonteCarlo),给定字号。
    static func muses(_ size: CGFloat) -> Font { .custom("MonteCarlo", size: size) }
}