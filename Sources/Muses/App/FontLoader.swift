import Foundation
import CoreText
import SwiftUI

/// App font registration: registers custom fonts bundled as resources into the process
/// so they can be used via `NSFont(name:)` / SwiftUI `.custom(_:size:)`.
@MainActor
enum FontLoader {
    private static var didRegister = false

    /// Registers the MonteCarlo font (used for the brand wordmark). Safe to call repeatedly (registers once).
    /// A registration failure only logs — startup is never blocked, since `.custom("MonteCarlo", ...)`
    /// silently falls back to the system font.
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

/// Brand wordmark font (MonteCarlo, an elegant script face). Used for the "Muses" wordmark.
/// If the font is not registered, `.custom` silently falls back to the system font, so no extra degradation logic is needed.
enum BrandFont {
    /// Muses brand wordmark font (MonteCarlo) at the given size.
    static func muses(_ size: CGFloat) -> Font { .custom("MonteCarlo", size: size) }
}