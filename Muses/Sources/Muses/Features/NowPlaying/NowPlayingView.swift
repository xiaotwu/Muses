import SwiftUI
import AppKit

/// 全屏 Now Playing 视图: 渐变背景(从封面主色派生) + 模式切换 + 频谱/波形/进度/歌词占位 + 手势。
/// 由 RootView 通过 .fullScreenCover 呈现。
struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @Environment(PlaybackService.self) private var playback

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var dragStartX: Double = 0

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }

    var body: some View {
        ZStack {
            // 渐变背景 + 深色罩
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.35).ignoresSafeArea())

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                centerContent
                Spacer(minLength: 16)
                bottomPanel
            }
            .padding(.horizontal, 48)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .focusable()
        .onKeyPress(.space) {
            playback.toggle()
            return .handled
        }
        .onAppear { extractGradient() }
        .onChange(of: playback.state.track?.id) {
            extractGradient()
        }
    }

    // MARK: - 顶部工具栏

    private var topBar: some View {
        HStack {
            Button { isPresented = false } label: {
                Image(systemName: "chevron.down").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColors.textPrimary)

            Spacer()

            Text("NOW PLAYING")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(BrandColors.textSecondary)
                .tracking(2)

            Spacer()

            Button { playback.toggle() } label: {
                Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColors.textPrimary)
        }
    }

    // MARK: - 中间: 按模式切换

    @ViewBuilder
    private var centerContent: some View {
        switch mode {
        case .cover:
            CoverArtModeView(artworkHash: playback.state.track?.artworkHash)
        case .vinyl:
            VinylModeView(artworkHash: playback.state.track?.artworkHash)
        }
    }

    // MARK: - 底部: 频谱 + 元信息 + 进度 + 波形 + 歌词

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            SpectrumView()

            // 标题 / Artist·Album / 音质徽标
            VStack(spacing: 4) {
                Text(playback.state.track?.title ?? "—")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                if let artist = playback.state.track?.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(BrandColors.textSecondary)
                        .lineLimit(1)
                }
                if let album = playback.state.track?.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
                qualityBadge
            }

            // 进度条(复用 seek Slider 逻辑)
            HStack(spacing: 8) {
                Text(format(playback.state.position))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(BrandColors.textSecondary)
                Slider(value: Binding(
                    get: { seeking ? seekValue : playback.state.position },
                    set: { v in seeking = true; seekValue = v }),
                    in: 0...max(playback.state.duration, 1),
                    onEditingChanged: { end in
                        if end { playback.seek(to: seekValue); seeking = false }
                    }
                )
                .tint(BrandColors.magenta)
                Text(format(playback.state.duration))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(BrandColors.textSecondary)
            }

            WaveformView()

            LyricsPlaceholderView()
        }
        // 水平拖拽 seek 手势(基于起始位置 + 偏移量)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    if !seeking {
                        seeking = true
                        dragStartX = playback.state.position
                    }
                    let delta = Double(v.translation.width) / 200.0   // 200pt = 1 秒
                    seekValue = max(0, min(playback.state.duration, dragStartX + delta))
                }
                .onEnded { _ in
                    if seeking { playback.seek(to: seekValue); seeking = false }
                }
        )
    }

    // MARK: - 音质徽标

    @ViewBuilder
    private var qualityBadge: some View {
        if let q = playback.state.quality {
            HStack(spacing: 6) {
                if q.isLossless {
                    badge("Hi-Res", color: BrandColors.green)
                }
                badge("\(q.sampleRate / 1000)kHz · \(q.bitDepth)-bit", color: BrandColors.cyan)
                Text(q.codec.uppercased())
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    // MARK: - 渐变提取

    private func extractGradient() {
        guard let h = playback.state.track?.artworkHash,
              let p = ArtworkCache.default.path(forHash: h),
              let img = NSImage(contentsOf: p) else {
            gradient = [BrandColors.background, BrandColors.surface]
            return
        }
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}