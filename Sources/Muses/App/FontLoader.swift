import Foundation
import CoreText
import SwiftUI

/// App font registration: registers custom fonts bundled as resources into the process
/// so they can be used via `NSFont(name:)` / SwiftUI `.custom(_:size:)`.
@MainActor
enum FontLoader {
    private static var didRegister = false

    /// Registers the IslandMoments font (used for the brand wordmark). Safe to call repeatedly (registers once).
    /// A registration failure only logs — startup is never blocked, since `.custom("IslandMoments-Regular", ...)`
    /// silently falls back to the system font.
    static func registerBrandFont() {
        guard !didRegister else { return }
        didRegister = true
        guard let url = MusesResources.islandMomentsFontURL else {
            AppLog.for("FontLoader").warning("IslandMoments-Regular.ttf resource not found, wordmark falling back to system font")
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            AppLog.for("FontLoader").warning("IslandMoments registration failed: \(desc)")
        }
    }
}

/// Brand wordmark font (IslandMoments, an elegant script face). Used for the product wordmark.
/// If the font is not registered, `.custom` silently falls back to the system font, so no extra degradation logic is needed.
@MainActor
enum BrandFont {
    static let wordmark = "Muses · Polyhymnia"

    /// Product wordmark font at the given size.
    static func muses(_ size: CGFloat) -> Font {
        .custom("IslandMoments-Regular", size: size * TypographyPreferences.shared.size.scale)
    }
}
