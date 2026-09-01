import SwiftUI
import AppKit

/// Semantic glass roles keep native glass behavior centralized instead of
/// scattering material choices through feature views.
enum MusesGlassRole: Equatable {
    case persistentChrome
    case player
    case floatingPanel
    case compactControl

    var isInteractive: Bool {
        self == .player || self == .compactControl
    }
}

/// Muses 玻璃原语:统一「持久/浮动 chrome」表面的玻璃呈现。
///
/// - macOS 26+:原生 `glassEffect(_:in:)`,系统提供真实 Liquid Glass。
/// - macOS 14/15:回退 `.ultraThinMaterial`(系统材质)。
/// - 开启「降低透明度」或「增强对比度」:回退不透明 `BrandColors.surface`,
///   保证可读性与无障碍(AGENTS.md:Legibility / Reduce Transparency)。
///
/// `tint` 仅用于语义(播放态/选中态);`nil` 表示中性玻璃,不做装饰性染色。
struct MusesGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let role: MusesGlassRole
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let opaque = (reduceTransparency
                     || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        if opaque {
            content.background(BrandColors.surface, in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glassVariant, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    @available(macOS 26.0, *)
    private var glassVariant: Glass {
        let base = tint.map { Glass.regular.tint($0) } ?? .regular
        return role.isInteractive ? base.interactive() : base
    }
}

/// 纯决策逻辑(可测试,不依赖 SwiftUI 环境渲染)。
enum GlassMode {
    case opaque, glass, material

    /// `supportsGlass`:运行时是否支持原生 Liquid Glass(macOS 26+)。
    static func mode(reduceTransparency: Bool,
                     increaseContrast: Bool,
                     supportsGlass: Bool) -> GlassMode {
        if reduceTransparency || increaseContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

/// 运行时判定是否在支持 `glassEffect` 的系统上(隔离 `#available`,便于测试注入)。
private var supportsLiquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}

extension View {
    /// 以给定形状应用 Muses 玻璃表面。
    func musesGlass<S: Shape>(in shape: S, tint: Color? = nil,
                              role: MusesGlassRole = .floatingPanel) -> some View {
        modifier(MusesGlass(shape: shape, tint: tint, role: role))
    }

    /// 便捷重载:连续圆角矩形(PlayerBar / 抽屉 / MiniPlayer 等常用形态)。
    func musesGlass(cornerRadius: CGFloat = 16, tint: Color? = nil,
                    role: MusesGlassRole = .floatingPanel) -> some View {
        modifier(MusesGlass(shape: RoundedRectangle(cornerRadius: cornerRadius,
                                                    style: .continuous), tint: tint, role: role))
    }

    /// Floating rounded panel used by the sidebar, Queue, Search, and sheets.
    func musesFloatingChrome(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .musesGlass(in: shape, role: .floatingPanel)
            .overlay(shape.stroke(BrandColors.textPrimary.opacity(0.12), lineWidth: 1))
    }

    /// Opaque black floating panel (Queue). Not glass.
    func musesOpaquePanel(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.black, in: shape)
            .clipShape(shape)
            .overlay(shape.stroke(BrandColors.textPrimary.opacity(0.12), lineWidth: 1))
    }

}
