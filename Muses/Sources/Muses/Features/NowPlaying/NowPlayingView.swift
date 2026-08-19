import SwiftUI
import AppKit

/// 全屏 Now Playing 视图(Apple Music 风格双栏):
/// 左栏 = 封面 + 元信息 + 传输控件 + 进度条 + 频谱;右栏 = 歌词 + 即将播放。
/// 由 RootView 通过 `.overlay` 呈现(`showNowPlaying`)。窄窗(<960pt)回退为单栏。
struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @Environment(PlaybackService.self) private var playback

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    /// Phase 22 §10.8:歌词呈现模式 inline/lyricsOnly/minimal。
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @State private var gradient: [Color] = [BrandColors.background, BrandColors.surface]
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var showLyrics = true

    var onShowQueue: () -> Void = {}

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }
    private var lyricsMode: NowPlayingLyricsMode { NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline }
    /// 歌词全屏呈现(lyricsOnly/minimal)时,左栏封面/控件让位。
    private var lyricsFullscreen: Bool { showLyrics && lyricsMode != .inline }

    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .overlay(BrandColors.scrim.ignoresSafeArea())

            GeometryReader { geo in
                let twoColumn = geo.size.width >= 960
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 48).padding(.top, 12)
                    if twoColumn {
                        twoColumnLayout
                            .padding(.horizontal, 48).padding(.bottom, 32).padding(.top, 12)
                    } else {
                        singleColumnLayout
                            .padding(.horizontal, 24).padding(.bottom, 32).padding(.top, 12)
                    }
                }
            }
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
        HStack(spacing: 16) {
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

            // 封面模式切换(cover / vinyl)
            Button {
                modeRaw = (mode == .cover ? NowPlayingMode.vinyl : NowPlayingMode.cover).rawValue
            } label: {
                Image(systemName: mode == .cover ? "square.stack.fill" : "opticaldisc")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColors.textSecondary)
            .help(mode == .cover ? tr("Cover", "封面") : tr("Vinyl", "唱片"))

            // 歌词栏显隐
            Button { showLyrics.toggle() } label: {
                Image(systemName: "quote.bubble").font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showLyrics ? BrandColors.magenta : BrandColors.textSecondary)
            .help(tr("Lyrics", "歌词"))

            // 歌词呈现模式(Phase 22):inline → lyricsOnly → minimal → inline
            Button {
                lyricsModeRaw = lyricsMode.next.rawValue
            } label: {
                Image(systemName: lyricsMode.iconName).font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(lyricsFullscreen ? BrandColors.magenta : BrandColors.textSecondary)
            .disabled(!showLyrics)
            .help(tr("Lyrics mode", "歌词模式"))

            // 偏移微调(Phase 22 §10.8):仅全屏歌词模式显示。
            if lyricsFullscreen {
                LyricsOffsetStepper()
            }

            // 音量
            HStack(spacing: 6) {
                Image(systemName: playback.volume > 0 ? "speaker.wave.2" : "speaker.slash")
                    .font(.caption).foregroundStyle(BrandColors.textSecondary)
                Slider(value: Binding(
                    get: { Double(playback.volume) },
                    set: { playback.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 80).tint(BrandColors.magenta)
            }
        }
    }

    // MARK: - 双栏布局

    private var twoColumnLayout: some View {
        Group {
            if lyricsFullscreen {
                // 全屏歌词模式:歌词占主区,左栏封面/控件隐藏(传输控件仍可达 via 顶部/键盘)。
                LyricsFullscreenView(mode: lyricsMode)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 40) {
                    leftColumn
                        .frame(maxWidth: .infinity)
                    if showLyrics {
                        rightColumn
                            .frame(width: 360)
                    }
                }
            }
        }
    }

    // MARK: - 单栏布局(窄窗回退)

    private var singleColumnLayout: some View {
        ScrollView {
            VStack(spacing: 24) {
                leftColumn
                if showLyrics { rightColumn }
            }
        }
    }

    // MARK: - 左栏:封面 + 元信息 + 传输 + 进度 + 频谱

    private var leftColumn: some View {
        VStack(spacing: 20) {
            centerContent

            metadataBlock

            transportControls

            scrubber

            SpectrumView()
                .frame(height: 48)
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var centerContent: some View {
        let source = ArtworkSource.resolve(for: playback.state.track)
        switch mode {
        case .cover:
            CoverArtModeView(source: source)
        case .vinyl:
            VinylModeView(source: source)
        }
    }

    private var metadataBlock: some View {
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
        .frame(maxWidth: 480)
    }

    /// Apple Music 顺序:shuffle / prev / play / next / repeat。
    private var transportControls: some View {
        HStack(spacing: 28) {
            Button { playback.queue.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3)
            }
            .foregroundStyle(playback.queue.shuffle ? BrandColors.magenta : BrandColors.textSecondary)
            .help(playback.queue.shuffle ? tr("Shuffle: On", "随机:开") : tr("Shuffle: Off", "随机:关"))

            Button { playback.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .foregroundStyle(BrandColors.textPrimary)

            Button { playback.toggle() } label: {
                Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
            }
            .foregroundStyle(BrandColors.magenta)

            Button { playback.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .foregroundStyle(BrandColors.textPrimary)

            Button { cycleRepeat() } label: {
                Image(systemName: playback.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
            }
            .foregroundStyle(playback.queue.repeatMode == .off
                             ? BrandColors.textSecondary : BrandColors.magenta)
            .help(repeatHelp)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 480)
    }

    private var scrubber: some View {
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
        .frame(maxWidth: 480)
    }

    // MARK: - 右栏:歌词 + 即将播放

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            LyricsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            UpNextPreview(onShowQueue: onShowQueue)
            // 曲目书签(Phase 21 §10.7):仅当当前曲目有书签时渲染,点击跳转。
            if let tid = playback.state.track?.id {
                BookmarksView(trackId: tid)
            }
        }
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
            .glow(color, radius: 2.5)
            .cornerRadius(4)
    }

    // MARK: - 传输辅助

    private func cycleRepeat() {
        let next: RepeatMode
        switch playback.queue.repeatMode {
        case .off:  next = .all
        case .all:  next = .one
        case .one:  next = .off
        }
        playback.queue.setRepeat(next)
    }

    private var repeatHelp: String {
        switch playback.queue.repeatMode {
        case .off: tr("Repeat: Off", "循环:关")
        case .all: tr("Repeat: All", "循环:全部")
        case .one: tr("Repeat: One", "循环:单曲")
        }
    }

    // MARK: - 渐变提取(本地 + YouTube 缩略图)

    private func extractGradient() {
        let source = ArtworkSource.resolve(for: playback.state.track)
        switch source {
        case .cached(let img):
            applyGradient(from: img)
        case .remote(let url):
            // 缩略图在后台解码 + 提色,避免阻塞主线程。
            Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url),
                      let img = NSImage(data: data) else {
                    await MainActor.run {
                        gradient = [BrandColors.background, BrandColors.surface]
                    }
                    return
                }
                let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
                await MainActor.run {
                    gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
                }
            }
        case .placeholder:
            gradient = [BrandColors.background, BrandColors.surface]
        }
    }

    private func applyGradient(from img: NSImage) {
        let colors = AlbumArtworkExtractor.dominantColors(img, count: 3)
        gradient = colors.map { Color(nsColor: $0) } + [BrandColors.background]
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}