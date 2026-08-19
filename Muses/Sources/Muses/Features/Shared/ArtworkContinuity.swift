import SwiftUI
import AppKit

enum ArtworkContinuityID: Hashable {
    case liveCover(UUID)
    case album(UUID)          // reserved, unused
    case artist(UUID)         // reserved, unused
    case playlist(UUID)       // reserved, unused
    case youTubeImport(UUID)  // reserved, unused
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
    @Environment(PlaybackService.self) private var playback
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]

    var body: some View {
        LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(BrandColors.scrim.ignoresSafeArea())
            .onAppear { extractGradient() }
            .onChange(of: playback.state.track?.id) { extractGradient() }
    }

    private func extractGradient() {
        let source = ArtworkSource.resolve(for: playback.state.track)
        let expectedID = playback.state.track?.id
        Task { @MainActor in
            let img = await Task.detached(priority: .userInitiated) {
                source.loadNSImage()
            }.value
            guard playback.state.track?.id == expectedID, let img else { return }
            let colors = AlbumArtworkExtractor.dominantColors(img, count: 4)
            gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
        }
    }
}

/// Slot-sized cover token above Now Playing chrome. Morphs still `CoverArtModeView`;
/// vinyl is a post-settle crossfade and is not the matched-geometry view.
struct LiveCoverHost: View {
    let source: ArtworkSource
    let trackID: UUID
    let namespace: Namespace.ID
    let isSource: Bool
    var isPresented: Bool = true

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @State private var showVinyl = false
    @State private var morphSettled = false

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }

    var body: some View {
        ZStack {
            CoverArtModeView(source: source)
                .opacity(showVinyl && isPresented ? 0 : 1)
                .matchedGeometryEffect(
                    id: ArtworkContinuityID.liveCover(trackID),
                    in: namespace,
                    isSource: isSource
                )
            if showVinyl && isPresented {
                VinylModeView(source: source)
            }
        }
        .frame(width: 480, height: 480)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(MusesMotion.nowPlayingMorph * 1_000_000_000))
            guard !Task.isCancelled else { return }
            morphSettled = true
            if mode == .vinyl {
                withAnimation(.easeInOut(duration: MusesMotion.overlay)) {
                    showVinyl = true
                }
            }
        }
        .onChange(of: modeRaw) {
            guard morphSettled else { return }
            withAnimation(.easeInOut(duration: MusesMotion.overlay)) {
                showVinyl = (mode == .vinyl)
            }
        }
        .onDisappear {
            morphSettled = false
            showVinyl = false
        }
    }
}
