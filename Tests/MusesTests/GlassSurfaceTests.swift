import Testing
import Foundation
@testable import Muses

/// Pure-logic tests for the Liquid Glass primitive decisions (GlassMode.mode).
///
/// A ViewModifier's rendered output cannot be asserted in a unit test, so the accessibility/usability decisions are extracted as pure functions,
/// pinning three contracts: reduce transparency → opaque; increase contrast → opaque; otherwise macOS 26+ → glass,
/// older systems → material.
@MainActor
struct GlassSurfaceTests {

    @Test("Accessibility off + supportsGlass -> .glass")
    func glassWhenSupported() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: false,
                              supportsGlass: true) == .glass)
    }

    @Test("Accessibility off + older system -> .material")
    func materialFallback() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: false,
                              supportsGlass: false) == .material)
    }

    @Test("Reduce transparency -> .opaque regardless of glass support")
    func reduceTransparencyOverrides() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: true) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: false) == .opaque)
    }

    @Test("Increase contrast -> .opaque regardless of glass support")
    func increaseContrastOverrides() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: true) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: false) == .opaque)
    }

    @Test("Both accessibility flags enabled -> .opaque")
    func bothAccessibilityFlags() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: true,
                              supportsGlass: true) == .opaque)
    }

    @Test("Material system respects accessibility flags when glass is unsupported")
    func materialRespectsAccessibility() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: false) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: false) == .opaque)
    }
}