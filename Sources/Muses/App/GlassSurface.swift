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

/// Muses glass primitive: one glass presentation for all persistent/floating chrome surfaces.
///
/// - macOS 26+: native `glassEffect(_:in:)` — the system provides real Liquid Glass.
/// - macOS 14/15: falls back to `.ultraThinMaterial` (system material).
/// - Reduce Transparency or Increase Contrast enabled: falls back to the opaque
///   `BrandColors.surface`, preserving legibility and accessibility (AGENTS.md:
///   Legibility / Reduce Transparency).
///
/// `tint` is semantic only (playing/selected states); `nil` means neutral glass with no decorative tinting.
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

/// Pure decision logic (testable, no SwiftUI environment rendering required).
enum GlassMode {
    case opaque, glass, material

    /// `supportsGlass`: whether the runtime supports native Liquid Glass (macOS 26+).
    static func mode(reduceTransparency: Bool,
                     increaseContrast: Bool,
                     supportsGlass: Bool) -> GlassMode {
        if reduceTransparency || increaseContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

/// Whether the runtime supports `glassEffect` (isolates `#available` for test injection).
private var supportsLiquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}

extension View {
    /// Applies the Muses glass surface with the given shape.
    func musesGlass<S: Shape>(in shape: S, tint: Color? = nil,
                              role: MusesGlassRole = .floatingPanel) -> some View {
        modifier(MusesGlass(shape: shape, tint: tint, role: role))
    }

    /// Convenience overload: continuous-corner rounded rectangle (the usual PlayerBar / drawer / MiniPlayer shape).
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
