import SwiftUI
import AppKit

/// Pure, testable geometry for the full-window Now Playing composition.
///
/// At the 1440×900 reference size the left stage is 404pt wide and the whole
/// composition is 1120pt wide, leaving balanced 160pt outer margins. Pausing
/// preserves the artwork and stage geometry; only playback-driven motion stops.
struct NowPlayingLayout: Equatable {
    enum Presentation: Equatable {
        case split
        case stacked
    }

    static let splitBreakpoint: CGFloat = 1_040
    static let referenceContentWidth: CGFloat = 1_120
    static let referenceStageSide: CGFloat = 404
    static let liveCoverPlayingScale: CGFloat = 1.06
    static let vinylVerticalOffset: CGFloat = -12
    static let edgeInset: CGFloat = 22
    static let topControlHeight: CGFloat = 32
    static let trafficLightControlGap: CGFloat = edgeInset

    static var topChromeHeight: CGFloat { edgeInset + topControlHeight }

    /// AppKit owns the traffic lights; the back control begins just after the
    /// native reserved region instead of reproducing or repositioning them.
    static var leadingControlInset: CGFloat {
        WindowChromeMetrics.trafficLightClearanceWidth + trafficLightControlGap
    }

    /// Mirror the back button's physical distance from the window edge on the
    /// trailing and lower chrome. This is intentionally larger than the local
    /// gap after AppKit's traffic-light reservation.
    static var mirroredOuterControlInset: CGFloat {
        leadingControlInset
    }

    let presentation: Presentation
    let contentWidth: CGFloat
    let stageSide: CGFloat
    let artworkSlotSide: CGFloat
    let artworkScale: CGFloat
    let columnGap: CGFloat
    let lyricsLeadingInset: CGFloat

    var renderedArtworkSide: CGFloat {
        artworkSlotSide * artworkScale
    }

    static func resolve(
        width: CGFloat,
        height: CGFloat,
        isPlaying: Bool,
        reduceMotion: Bool = false
    ) -> Self {
        let safeWidth = max(0, width)
        let safeHeight = max(0, height)
        let presentation: Presentation = safeWidth >= splitBreakpoint ? .split : .stacked
        let artworkScale = reduceMotion ? 1 : liveCoverPlayingScale

        if presentation == .split {
            // Preserve the reference's calm outer field as the window narrows;
            // giving all spare width to the columns makes the cover cling to
            // the leading edge and the lyrics feel detached from it.
            let contentWidth = min(referenceContentWidth, max(0, safeWidth - 300))
            let stageSide = min(referenceStageSide, max(292, safeHeight * 0.45))
            let gap = min(144, max(64, 64 + (safeWidth - splitBreakpoint) * 0.2))
            let slotSide = stageSide / artworkScale
            return Self(
                presentation: presentation,
                contentWidth: contentWidth,
                stageSide: stageSide,
                artworkSlotSide: slotSide,
                artworkScale: artworkScale,
                columnGap: gap,
                lyricsLeadingInset: safeWidth >= 1_320 ? 30 : 18
            )
        }

        let stageSide = min(360, max(248, min(safeWidth - 64, safeHeight * 0.58)))
        let slotSide = stageSide / artworkScale
        return Self(
            presentation: presentation,
            contentWidth: max(0, safeWidth - 48),
            stageSide: stageSide,
            artworkSlotSide: slotSide,
            artworkScale: artworkScale,
            columnGap: 0,
            lyricsLeadingInset: 0
        )
    }
}

enum NowPlayingInputPolicy {
    static func acceptsGlobalKeyEvents(
        nowPlayingPresented: Bool,
        settingsPresented: Bool
    ) -> Bool {
        nowPlayingPresented && !settingsPresented
    }
}

enum NowPlayingPresentationPolicy {
    /// Final Open Design prototype: dismissal is opacity-only for 300ms.
    static let dismissDuration: TimeInterval = 0.30

    static func acceptsInteraction(isPresented: Bool, settingsPresented: Bool) -> Bool {
        isPresented && !settingsPresented
    }

    static func isAccessibilityVisible(isPresented: Bool, settingsPresented: Bool) -> Bool {
        acceptsInteraction(isPresented: isPresented, settingsPresented: settingsPresented)
    }
}

/// Now Playing offers physical output endpoints, not every Core Audio object.
/// Keep the filtering view-local so AudioDeviceService remains the complete
/// diagnostic inventory used by Audio Nerd surfaces.
enum NowPlayingOutputDevicePolicy {
    static let menuLabelWidth: CGFloat = 168

    static func visibleDevices(
        _ devices: [AudioDeviceService.AudioDevice]
    ) -> [AudioDeviceService.AudioDevice] {
        var seenNames = Set<String>()
        return devices.filter { device in
            let trimmedName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = trimmedName.lowercased()
            guard device.channels > 0,
                  !trimmedName.isEmpty,
                  !normalizedName.contains("microphone"),
                  !normalizedName.contains("aggregate"),
                  seenNames.insert(normalizedName).inserted else {
                return false
            }
            return true
        }
    }
}

enum NowPlayingVolumePolicy {
    static let silenceThreshold: Float = 0.001
    static let fallbackAudibleVolume: Float = 0.8

    static func isMuted(_ volume: Float) -> Bool {
        volume <= silenceThreshold
    }

    static func rememberedAudibleVolume(current: Float, previous: Float) -> Float {
        guard !isMuted(current) else { return previous }
        return max(0, min(1, current))
    }

    static func toggledVolume(current: Float, remembered: Float) -> Float {
        guard isMuted(current) else { return 0 }
        let candidate = isMuted(remembered) ? fallbackAudibleVolume : remembered
        return max(0, min(1, candidate))
    }
}

/// Full-window Now Playing: fixed artwork stage and controls at leading,
/// distance-layered lyrics at trailing, and compact semantic glass chrome.
struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @Binding var showLyrics: Bool
    @Binding var settingsPresented: Bool
    var coverHostedExternally: Bool = false

    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(AudioDeviceService.self) private var audioDevices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @State private var escapeMonitor: Any?
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var rememberedAudibleVolume = NowPlayingVolumePolicy.fallbackAudibleVolume

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }
    private var lyricsMode: NowPlayingLyricsMode {
        NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline
    }
    private var lyricsFullscreen: Bool { showLyrics && lyricsMode != .inline }
    private var outputDevices: [AudioDeviceService.AudioDevice] {
        NowPlayingOutputDevicePolicy.visibleDevices(audioDevices.devices)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = NowPlayingLayout.resolve(
                width: proxy.size.width,
                height: proxy.size.height,
                isPlaying: playback.state.isPlaying,
                reduceMotion: reduceMotion
            )

            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    topChrome
                        .frame(height: NowPlayingLayout.topChromeHeight, alignment: .top)

                    if playback.state.track == nil {
                        emptyState
                    } else if lyricsFullscreen {
                        LyricsFullscreenView(mode: lyricsMode)
                            .padding(.horizontal, layout.presentation == .split ? 48 : 24)
                            .padding(.bottom, 48)
                    } else {
                        switch layout.presentation {
                        case .split:
                            splitContent(layout)
                        case .stacked:
                            stackedContent(layout)
                        }
                    }
                }

                if playback.state.track != nil {
                    lyricsOptions
                        .padding(.trailing, NowPlayingLayout.mirroredOuterControlInset)
                        .padding(.bottom, NowPlayingLayout.mirroredOuterControlInset)
                }
            }
        }
        .onExitCommand {
            guard acceptsGlobalKeyEvents else { return }
            isPresented = false
        }
        .onKeyPress(.space) {
            guard acceptsGlobalKeyEvents else { return .ignored }
            playback.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            guard acceptsGlobalKeyEvents else { return .ignored }
            isPresented = false
            return .handled
        }
        .onAppear {
            if audioDevices.devices.isEmpty {
                audioDevices.refresh()
            }
            rememberedAudibleVolume = NowPlayingVolumePolicy.rememberedAudibleVolume(
                current: playback.volume,
                previous: rememberedAudibleVolume
            )
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard acceptsGlobalKeyEvents else { return event }
                if event.keyCode == 53 {
                    isPresented = false
                    return nil
                }
                return event
            }
        }
        .onChange(of: playback.state.track?.id) {
            seeking = false
        }
        .onChange(of: playback.volume) { _, volume in
            rememberedAudibleVolume = NowPlayingVolumePolicy.rememberedAudibleVolume(
                current: volume,
                previous: rememberedAudibleVolume
            )
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    private var acceptsGlobalKeyEvents: Bool {
        NowPlayingInputPolicy.acceptsGlobalKeyEvents(
            nowPlayingPresented: isPresented,
            settingsPresented: settingsPresented
        )
    }

    private var topChrome: some View {
        HStack(spacing: 12) {
            Button { isPresented = false } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrandColors.textPrimary)
                    .frame(width: 34, height: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .musesGlass(in: Capsule(), role: .compactControl)
            .overlay(Capsule().stroke(BrandColors.hairline, lineWidth: 1))
            .help(tr("Back", "返回"))
            .accessibilityLabel(tr("Close Now Playing", "关闭正在播放"))

            Spacer()

            outputAndVolume
        }
        .padding(.leading, NowPlayingLayout.leadingControlInset)
        .padding(.trailing, NowPlayingLayout.mirroredOuterControlInset)
        .padding(.top, NowPlayingLayout.edgeInset)
    }

    private var outputAndVolume: some View {
        LiquidGlassVolumeBar(width: 220, height: 32)
            .blocksWindowDrag()
    }

    private var outputMenu: some View {
        Menu {
            if outputDevices.isEmpty {
                Text(tr("No audio outputs available", "无可用音频输出"))
            } else {
                ForEach(outputDevices) { device in
                    Button {
                        _ = audioDevices.setDefault(device.id)
                    } label: {
                        Label {
                            Text(device.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(
                                    width: NowPlayingOutputDevicePolicy.menuLabelWidth,
                                    alignment: .leading
                                )
                        } icon: {
                            Image(systemName: device.id == audioDevices.defaultDeviceID
                                ? "checkmark"
                                : "speaker.wave.2")
                                .frame(width: 16)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.magenta)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help(tr("Audio output", "音频输出"))
        .accessibilityLabel(tr("Choose audio output", "选择音频输出"))
    }

    private func splitContent(_ layout: NowPlayingLayout) -> some View {
        HStack(alignment: .center, spacing: layout.columnGap) {
            leftColumn(layout)
                .frame(width: layout.stageSide)

            LyricsView(layout: .leading)
                .padding(.leading, layout.lyricsLeadingInset)
                .padding(.top, 18)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: layout.contentWidth)
        .frame(maxHeight: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stackedContent(_ layout: NowPlayingLayout) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                leftColumn(layout)
                    .frame(width: layout.stageSide)

                LyricsView(layout: .leading)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 72)
        }
        .scrollIndicators(.hidden)
    }

    private func leftColumn(_ layout: NowPlayingLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                centerContent(size: layout.artworkSlotSide, scale: layout.artworkScale)
            }
            .frame(width: layout.stageSide, height: layout.stageSide)

            trackIdentity
                .padding(.top, 14)

            seekRow
                .padding(.top, 13)

            transportRow
                .padding(.top, 6)
        }
        .frame(width: layout.stageSide)
    }

    private var trackIdentity: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.state.track?.title ?? "—")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(2)

                Text(subtitleLine)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(BrandColors.textPrimary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            likeButton
            moreMenu
        }
        .frame(minHeight: 48, alignment: .top)
    }

    private var moreMenu: some View {
        Menu {
            Button(tr("Play Next", "下一首播放")) {
                if let track = playback.state.track { playback.queue.playNext(track) }
            }
            Button(tr("Add to Queue", "加入队列")) {
                if let track = playback.state.track { playback.queue.addToQueue(track) }
            }
            if let videoID = playback.state.track?.youTubeId,
               let url = URL(string: "https://youtu.be/\(videoID)") {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label {
                        Text(tr("Open on YouTube", "在 YouTube 打开"))
                    } icon: {
                        YouTubeMark(size: 12)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(BrandColors.textPrimary.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .disabled(playback.state.track == nil)
        .help(tr("More", "更多"))
        .accessibilityLabel(tr("More playback actions", "更多播放操作"))
    }

    private var likeButton: some View {
        let _ = library.likedRevision
        let liked = playback.state.track.map { library.isLiked(id: $0.id) } ?? false
        return Button {
            if let id = playback.state.track?.id { library.toggleLike(id: id) }
        } label: {
            Image(systemName: liked ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(liked ? BrandColors.magenta : BrandColors.textPrimary.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(BrandColors.textPrimary.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏"))
        .accessibilityLabel(liked
            ? tr("Unlike current song", "取消收藏当前歌曲")
            : tr("Like current song", "收藏当前歌曲"))
        .disabled(playback.state.track == nil)
    }

    private var seekRow: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { seeking ? seekValue : playback.state.position },
                    set: { value in
                        seeking = true
                        seekValue = value
                    }
                ),
                in: 0...max(playback.state.duration, 1),
                onEditingChanged: { editing in
                    if !editing {
                        playback.seek(to: seekValue)
                        seeking = false
                    }
                }
            )
            .controlSize(.mini)
            .tint(BrandColors.magenta)
            .blocksWindowDrag()
            .accessibilityLabel(tr("Playback position", "播放进度"))
            .accessibilityValue(
                "\(formatTime(displayedPosition)) / \(formatTime(playback.state.duration))"
            )

            HStack {
                Text(formatTime(displayedPosition))
                Spacer()
                Text("−" + formatTime(max(0, playback.state.duration - displayedPosition)))
            }
            .overlay {
                if let qualityLabel {
                    Label(qualityLabel, systemImage: "waveform")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BrandColors.textPrimary.opacity(0.42))
                }
            }
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .foregroundStyle(BrandColors.textPrimary.opacity(0.6))
        }
    }

    private var transportRow: some View {
        HStack(spacing: 0) {
            transportButton(
                systemName: "shuffle",
                selected: playback.queue.shuffle,
                help: tr("Shuffle", "随机")
            ) {
                playback.queue.toggleShuffle()
            }

            Spacer()

            HStack(spacing: 26) {
                transportButton(
                    systemName: "backward.end.fill",
                    help: tr("Previous", "上一首")
                ) {
                    playback.previous()
                }

                Button { playback.toggle() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BrandColors.textPrimary)
                        .offset(x: playback.state.isPlaying ? 0 : 1)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放"))
                .accessibilityLabel(
                    playback.state.isPlaying ? tr("Pause", "暂停") : tr("Play", "播放")
                )

                transportButton(
                    systemName: "forward.end.fill",
                    help: tr("Next", "下一首")
                ) {
                    playback.next()
                }
            }

            Spacer()

            transportButton(
                systemName: repeatSymbol,
                selected: playback.queue.repeatMode != .off,
                drawsBackground: true,
                help: repeatHelp
            ) {
                playback.queue.setRepeat(playback.queue.repeatMode.next)
            }
        }
        .frame(height: 40)
    }

    private func transportButton(
        systemName: String,
        selected: Bool = false,
        drawsBackground: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? BrandColors.magenta : BrandColors.textPrimary.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(
                    drawsBackground ? BrandColors.textPrimary.opacity(0.12) : .clear,
                    in: Circle()
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(selected ? tr("On", "开启") : tr("Off", "关闭"))
    }

    private var lyricsOptions: some View {
        Menu {
            lyricsModeButton(
                .inline,
                title: tr("Inline lyrics", "内联歌词")
            )
            lyricsModeButton(
                .lyricsOnly,
                title: tr("Lyrics only", "仅歌词")
            )
            lyricsModeButton(
                .minimal,
                title: tr("Minimal lyric", "极简歌词")
            )
            Divider()
            Button(tr("Lyrics Settings…", "歌词设置…")) {
                NotificationCenter.default.post(
                    name: .musesOpenSettings,
                    object: SettingsCategory.lyrics
                )
            }
        } label: {
            Image(systemName: "quote.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary.opacity(0.78))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .musesGlass(in: Circle(), role: .compactControl)
        .overlay(Circle().stroke(BrandColors.hairline, lineWidth: 1))
        .help(tr("Lyrics options", "歌词选项"))
        .accessibilityLabel(tr("Lyrics display options", "歌词显示选项"))
    }

    private func lyricsModeButton(_ mode: NowPlayingLyricsMode, title: String) -> some View {
        Button {
            lyricsModeRaw = mode.rawValue
            showLyrics = mode != .inline
        } label: {
            Label(title, systemImage: lyricsMode == mode ? "checkmark" : mode.iconName)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(BrandColors.textSecondary)
                .accessibilityHidden(true)
            Text(tr("Nothing Playing", "暂无播放"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(BrandColors.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var displayedPosition: Double {
        seeking ? seekValue : playback.state.position
    }

    private var subtitleLine: String {
        guard let track = playback.state.track else { return " " }
        if let album = track.albumTitle, !album.isEmpty {
            return "\(track.artist) — \(album)"
        }
        return track.artist
    }

    private var qualityLabel: String? {
        guard let quality = playback.state.quality else { return nil }
        if quality.isLossless {
            return tr("Lossless", "无损")
        }

        var parts: [String] = []
        let codec = quality.codec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codec.isEmpty, codec.lowercased() != "native" {
            parts.append(codec)
        }
        if quality.sampleRate > 0 {
            parts.append("\(quality.sampleRate / 1_000) kHz")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var volumeSymbol: String {
        let value = playback.volume
        if value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.34 { return "speaker.fill" }
        if value < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func toggleMute() {
        let target = NowPlayingVolumePolicy.toggledVolume(
            current: playback.volume,
            remembered: rememberedAudibleVolume
        )
        if !NowPlayingVolumePolicy.isMuted(playback.volume) {
            rememberedAudibleVolume = playback.volume
        }
        playback.setVolume(target)
    }

    private var repeatSymbol: String {
        playback.queue.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatHelp: String {
        switch playback.queue.repeatMode {
        case .off: tr("Repeat: Off", "循环：关")
        case .one: tr("Repeat: One", "循环：单曲")
        case .all: tr("Repeat: Playlist", "循环：歌单")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    @ViewBuilder
    private func centerContent(size: CGFloat, scale: CGFloat) -> some View {
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
                        .offset(y: NowPlayingLayout.vinylVerticalOffset)
                }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .shadow(
            color: .black.opacity(playback.state.isPlaying ? 0.3 : 0.16),
            radius: playback.state.isPlaying ? 18 : 10,
            y: playback.state.isPlaying ? 8 : 5
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.35),
            value: playback.state.isPlaying
        )
        .accessibilityLabel(playback.state.track?.title ?? tr("Artwork", "封面"))
    }
}
