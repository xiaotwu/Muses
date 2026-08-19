import SwiftUI
import AppKit

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
        tint.map { Glass.regular.tint($0) } ?? .regular
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
    func musesGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(MusesGlass(shape: shape, tint: tint))
    }

    /// 便捷重载:连续圆角矩形(PlayerBar / 抽屉 / MiniPlayer 等常用形态)。
    func musesGlass(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(MusesGlass(shape: RoundedRectangle(cornerRadius: cornerRadius,
                                                    style: .continuous), tint: tint))
    }

    /// 轻微发光(issue #5):深色主题下白色文字 + 白色阴影 = 柔光;浅色主题黑色文字 + 黑色阴影 = 暗辉。
    /// 仅用于表达性表面的强调文字,静态、克制,不影响可读性。
    func glow(_ color: Color, radius: CGFloat = 2.5) -> some View {
        self.shadow(color: color, radius: radius)
    }
}