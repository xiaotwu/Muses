import SwiftUI
import AppKit

enum ArtworkContinuityID: Hashable {
    case liveCover(UUID)
    case album(UUID)          // reserved, unused
    case artist(UUID)         // reserved, unused
    case playlist(UUID)       // reserved, unused
    case youTubeImport(UUID)  // reserved, unused
}

/// Pure palette shaping for the expressive Now Playing atmosphere. Very bright
/// neutral samples are ignored when richer samples exist, and every retained
/// color is capped before it reaches the full-window gradient.
enum ArtworkAtmospherePalette {
    static let maximumBrightness: CGFloat = 0.50

    static func colors(from samples: [NSColor]) -> [NSColor] {
        let converted = samples.compactMap { $0.usingColorSpace(.sRGB) }
        let candidates = converted.filter { !isOverbrightNeutral($0) }
        return (candidates.isEmpty ? converted : candidates).map(toned)
    }

    /// Light glass keeps chromatic samples instead of expanding dark neutral clusters.
    static func lightColors(from samples: [NSColor]) -> [NSColor] {
        let converted = samples.compactMap { $0.usingColorSpace(.sRGB) }
        let chromatic = converted.filter { color in
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return saturation > 0.12 && brightness > 0.15
        }
        return Array((chromatic.isEmpty ? converted : chromatic).prefix(3))
    }

    static func brightness(of color: NSColor) -> CGFloat {
        guard let converted = color.usingColorSpace(.sRGB) else { return 0 }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        return brightness
    }

    private static func isOverbrightNeutral(_ color: NSColor) -> Bool {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        return brightness > 0.84 && saturation < 0.14
    }

    private static func toned(_ color: NSColor) -> NSColor {
        guard let converted = color.usingColorSpace(.sRGB) else { return .black }
        let maximumComponent = max(converted.redComponent,
                                   converted.greenComponent,
                                   converted.blueComponent)
        guard maximumComponent > 0 else { return .black }
        let targetBrightness = min(max(maximumComponent * 0.62, 0.14), maximumBrightness)
        let scale = targetBrightness / maximumComponent
        return NSColor(
            srgbRed: converted.redComponent * scale,
            green: converted.greenComponent * scale,
            blue: converted.blueComponent * scale,
            alpha: 1
        )
    }
}

/// Protects controls and lyrics from artwork-derived gradients. Both layers
/// use fixed near-black rather than a dynamic page color, preventing a light
/// appearance from introducing a white band into the artwork atmosphere.
struct ArtworkReadableScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.28),
                    .init(color: Color.black.opacity(0.24), location: 0.62),
                    .init(color: Color(red: 0.015, green: 0.018, blue: 0.025).opacity(0.92),
                          location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.34),
                    .init(color: Color.black.opacity(0.12), location: 0.66),
                    .init(color: Color.black.opacity(0.30), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct ArtworkWorldNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var artworkWorldNamespace: Namespace.ID? {
        get { self[ArtworkWorldNamespaceKey.self] }
        set { self[ArtworkWorldNamespaceKey.self] = newValue }
    }
}

struct CoverSlotPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Full-window Now Playing environment: gradient + scrim, behind chrome and the live cover.
struct NowPlayingEnvironmentLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lightGradient: [Color] = [.clear]
    @State private var gradient: [Color] = [
        Color(red: 0.10, green: 0.12, blue: 0.18),
        Color(red: 0.035, green: 0.040, blue: 0.055)
    ]

    private var requiresOpaqueBackground: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var body: some View {
        Group {
            if requiresOpaqueBackground {
                BrandColors.background
            } else if colorScheme == .light {
                LinearGradient(colors: [.white, Color(nsColor: .windowBackgroundColor)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        RadialGradient(colors: lightGradient + [.clear],
                                       center: .topLeading, startRadius: 0, endRadius: 1_100)
                            .opacity(0.55)
                    }
                    .overlay {
                        RadialGradient(colors: lightGradient.reversed() + [.clear],
                                       center: .bottomTrailing, startRadius: 0, endRadius: 900)
                            .opacity(0.38)
                    }
            } else {
                LinearGradient(
                    colors: gradient + [Color(red: 0.025, green: 0.028, blue: 0.038)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                    .overlay(ArtworkReadableScrim())
            }
        }
            .ignoresSafeArea()
            .task(id: playback.state.track?.id) {
                lightGradient = [.clear]
                gradient = [Color(red: 0.10, green: 0.12, blue: 0.18),
                            Color(red: 0.035, green: 0.040, blue: 0.055)]
                guard !requiresOpaqueBackground else { return }
                await extractGradient()
            }
            .onChange(of: reduceTransparency) {
                if !requiresOpaqueBackground { Task { await extractGradient() } }
            }
    }

    @MainActor
    private func extractGradient() async {
        let source = ArtworkSource.resolve(for: playback.state.track)
        let expectedID = playback.state.track?.id
        guard case .remote(let url) = source,
              let image = await ImageLoader.shared.load(url).value,
              !Task.isCancelled, playback.state.track?.id == expectedID else { return }
        let colors = AlbumArtworkExtractor.dominantColors(image, count: 4)
        lightGradient = ArtworkAtmospherePalette.lightColors(from: colors).map { Color(nsColor: $0) }
        gradient = ArtworkAtmospherePalette.colors(from: colors).map { Color(nsColor: $0) }
    }

}

/// Slot-sized cover token above Now Playing chrome. Morphs still `CoverArtModeView`;
/// vinyl is a post-settle crossfade and is not the matched-geometry view.
struct LiveCoverHost: View {
    let source: ArtworkSource
    let trackID: UUID
    let namespace: Namespace.ID
    let size: CGFloat
    let isSource: Bool
    var isPresented: Bool = true

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVinyl = false
    @State private var morphSettled = false

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }

    var body: some View {
        ZStack {
            CoverArtModeView(source: source, size: size)
                .opacity(showVinyl && isPresented ? 0 : 1)
                .matchedGeometryEffect(
                    id: ArtworkContinuityID.liveCover(trackID),
                    in: namespace,
                    isSource: isSource
                )
            if showVinyl && isPresented {
                VinylModeView(source: source, size: size)
                    .offset(y: NowPlayingLayout.vinylVerticalOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(MusesMotion.nowPlayingMorph * 1_000_000_000))
            guard !Task.isCancelled else { return }
            morphSettled = true
            if mode == .vinyl {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: MusesMotion.overlay)) {
                    showVinyl = true
                }
            }
        }
        .onChange(of: modeRaw) {
            guard morphSettled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: MusesMotion.overlay)) {
                showVinyl = (mode == .vinyl)
            }
        }
        .onDisappear {
            morphSettled = false
            showVinyl = false
        }
    }
}
