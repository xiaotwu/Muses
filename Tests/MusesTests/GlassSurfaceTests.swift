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

    @Test("无障碍关闭 + macOS26 → .glass")
    func glassWhenSupported() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: false,
                              supportsGlass: true) == .glass)
    }

    @Test("无障碍关闭 + 旧系统 → .material")
    func materialFallback() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: false,
                              supportsGlass: false) == .material)
    }

    @Test("降低透明度 → .opaque(无论是否支持玻璃)")
    func reduceTransparencyOverrides() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: true) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: false) == .opaque)
    }

    @Test("增强对比度 → .opaque(无论是否支持玻璃)")
    func increaseContrastOverrides() {
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: true) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: false) == .opaque)
    }

    @Test("两项无障碍同时开启 → .opaque(优先无障碍,不回退材质)")
    func bothAccessibilityFlags() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: true,
                              supportsGlass: true) == .opaque)
    }

    @Test("降低透明度优先于玻璃,但材质系统在无玻璃时仍受无障碍覆盖")
    func materialRespectsAccessibility() {
        #expect(GlassMode.mode(reduceTransparency: true, increaseContrast: false,
                              supportsGlass: false) == .opaque)
        #expect(GlassMode.mode(reduceTransparency: false, increaseContrast: true,
                              supportsGlass: false) == .opaque)
    }
}