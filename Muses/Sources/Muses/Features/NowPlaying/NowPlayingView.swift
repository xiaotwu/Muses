import SwiftUI
import AppKit

/// Now Playing content slot: large square (or vinyl circle) + lyrics.
/// Transport stays in the dock below.
struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @Binding var showLyrics: Bool
    var coverHostedExternally: Bool = false
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @State private var escapeMonitor: Any?

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }
    private var lyricsMode: NowPlayingLyricsMode { NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline }
    private var lyricsFullscreen: Bool { showLyrics && lyricsMode != .inline }

    var body: some View {
        GeometryReader { geo in
            let twoColumn = geo.size.width >= 960
            let coverSide = min(420, max(240, geo.size.height - 120))
            VStack(spacing: 0) {
                HStack {
                    ChromeIconButton(
                        systemName: "xmark",
                        help: tr("Close", "关闭"),
                        accessibility: tr("Close Now Playing", "关闭正在播放")
                    ) { isPresented = false }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                if lyricsFullscreen {
                    LyricsFullscreenView(mode: lyricsMode)
                        .padding(.horizontal, 48)
                } else if twoColumn {
                    HStack(alignment: .center, spacing: 56) {
                        leftColumn(coverSide: coverSide)
                            .frame(width: coverSide)
                        LyricsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 56)
                    .padding(.bottom, 16)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            leftColumn(coverSide: min(coverSide, geo.size.width - 48))
                            LyricsView().frame(minHeight: 220)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .focusEffectDisabled()
        .onExitCommand { isPresented = false }
        .onKeyPress(.space) {
            playback.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    isPresented = false
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    private func leftColumn(coverSide: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            centerContent(size: coverSide)
            VStack(alignment: .leading, spacing: 4) {
                Text(playback.state.track?.title ?? "—")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text(subtitleLine)
                    .font(.subheadline)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func centerContent(size: CGFloat) -> some View {
        Group {
            if coverHostedExternally {
                Color.clear
                    .frame(width: size, height: size)
                    .anchorPreference(key: CoverSlotPreferenceKey.self, value: .bounds) { $0 }
            } else {
                let source = ArtworkSource.resolve(for: playback.state.track)
                switch mode {
                case .cover:
                    CoverArtModeView(source: source, size: size)
                case .vinyl:
                    VinylModeView(source: source, size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(playback.state.isPlaying && !reduceMotion ? 1.04 : 1.0)
        .shadow(color: .black.opacity(playback.state.isPlaying ? 0.35 : 0),
                radius: playback.state.isPlaying ? 12 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: playback.state.isPlaying)
        .accessibilityLabel(playback.state.track?.title ?? tr("Artwork", "封面"))
    }

    private var subtitleLine: String {
        guard let track = playback.state.track else { return " " }
        if let album = track.albumTitle, !album.isEmpty {
            return "\(track.artist) — \(album)"
        }
        return track.artist
    }
}
