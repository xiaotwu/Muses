import SwiftUI
import AppKit

/// Pure, testable geometry for the full-window Now Playing composition.
///
/// Artwork grows with both available height and width. Pausing preserves its
/// geometry; hiding lyrics centers the same artwork without changing identity.
struct NowPlayingLayout: Equatable {
    enum Presentation: Equatable {
        case split
        case stacked
        case centered
    }

    static let splitBreakpoint: CGFloat = 1_040
    static let liveCoverPlayingScale: CGFloat = 1.06
    static let vinylVerticalOffset: CGFloat = -12
    static let edgeInset: CGFloat = 22
    static let dockBottomInset: CGFloat = 52
    static let artworkIdentityGap: CGFloat = 32
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
        reduceMotion: Bool = false,
        showsLyrics: Bool = true
    ) -> Self {
        let safeWidth = max(0, width)
        let safeHeight = max(0, height)
        let presentation: Presentation = !showsLyrics ? .centered
            : (safeWidth >= splitBreakpoint ? .split : .stacked)
        let artworkScale = reduceMotion ? 1 : liveCoverPlayingScale

        if presentation == .split {
            // Reserve room for song identity and the shared bottom dock.
            let contentWidth = min(1_600, max(0, safeWidth - 96))
            let stageSide = min(620, max(248, min(safeHeight - 270, contentWidth * 0.43)))
            let gap = min(112, max(40, safeWidth * 0.06))
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

        let stageSide = min(showsLyrics ? 420 : 620,
                            max(200, min(safeWidth - 64, safeHeight - (showsLyrics ? 270 : 340))))
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
    static func acceptsGlobalKeyEvents(nowPlayingPresented: Bool) -> Bool {
        nowPlayingPresented
    }
}

enum NowPlayingPresentationPolicy {
    /// Final Open Design prototype: dismissal is opacity-only for 300ms.
    static let dismissDuration: TimeInterval = 0.30

    static func acceptsInteraction(isPresented: Bool) -> Bool {
        isPresented
    }

    static func isAccessibilityVisible(isPresented: Bool) -> Bool {
        acceptsInteraction(isPresented: isPresented)
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

/// Responsive artwork, optional trailing lyrics and a shared glass control dock.
struct NowPlayingView: View {
    @Binding var isPresented: Bool
    @Binding var showLyrics: Bool
    var coverHostedExternally: Bool = false
    var onReturn: () -> Void

    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(YouTubeImportService.self) private var importService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PrefKey.nowPlayingMode) private var modeRaw: String = NowPlayingMode.cover.rawValue
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var lyricsModeRaw: String = NowPlayingLyricsMode.inline.rawValue
    @State private var escapeMonitor: Any?
    @State private var seeking = false
    @State private var lyricsInteractionPresented = false
    @State private var chaptersPresented = false
    @State private var seekValue: Double = 0
    @State private var volumePresented = false
    @State private var lastVolumeEscapeTimestamp: TimeInterval?
    @AppStorage(PrefKey.gestureClosePlayer) private var swipeClose = true
    @AppStorage(PrefKey.gestureChangeTrack) private var swipeTracks = false
    @AppStorage(PrefKey.gestureShowLyrics) private var swipeLyrics = false
    @State private var volumeEscapeHandled = false
    @State private var volumeEscapePending = false
    @State private var rememberedAudibleVolume = NowPlayingVolumePolicy.fallbackAudibleVolume
    @State private var presentationRow: CollectionTrackRow?
    @State private var songMetadata: YTDlpBridge.YTDlpPlaylistEntry?

    private var songInformation: SongDisplayInformation? {
        guard let track = playback.transportState.track else { return nil }
        let row = presentationRow.flatMap { $0.snapshot.id == track.id ? $0 : nil }
            ?? CollectionTrackRow(snapshot: track, canonicalIndex: 0)
        return SongDisplayInformation(row: row, metadata: songMetadata)
    }

    private var mode: NowPlayingMode { NowPlayingMode(rawValue: modeRaw) ?? .cover }
    private var lyricsMode: NowPlayingLyricsMode {
        NowPlayingLyricsMode(rawValue: lyricsModeRaw) ?? .inline
    }
    private var lyricsFullscreen: Bool { lyricsMode != .inline }

    var body: some View {
        GeometryReader { proxy in
            let layout = NowPlayingLayout.resolve(
                width: proxy.size.width,
                height: proxy.size.height,
                isPlaying: playback.state.isPlaying,
                reduceMotion: reduceMotion,
                showsLyrics: showLyrics
            )

            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {

                    if playback.state.track == nil {
                        emptyState
                    } else if lyricsFullscreen {
                        LyricsFullscreenView(mode: lyricsMode)
                            .padding(.horizontal, layout.presentation == .split ? 48 : 24)
                            .padding(.bottom, 24)
                    } else {
                        switch layout.presentation {
                        case .split:
                            splitContent(layout)
                        case .stacked:
                            stackedContent(layout)
                        case .centered:
                            leftColumn(layout, centered: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.bottom, 180)
                        }
                    }
                }
                if playback.state.track != nil, !lyricsFullscreen {
                    playbackDock(width: min(668, max(280, proxy.size.width - 48)))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, NowPlayingLayout.dockBottomInset)
                }
            }
        }
        .background {
            PlayerGestureInput(enabled: acceptsGlobalKeyEvents && !volumePresented && !chaptersPresented,
                close: swipeClose, tracks: swipeTracks, lyrics: swipeLyrics,
                hasLyricsColumn: showLyrics || lyricsFullscreen) { action in
                switch action {
                case .close: onReturn()
                case .next: playback.next()
                case .previous: playback.previous()
                case .lyrics: showLyrics = true
                }
            }
        }
        .onPreferenceChange(LyricsInteractionPresentedKey.self) { lyricsInteractionPresented = $0 }
        .task(id: playback.transportState.track?.id) {
            songMetadata = nil
            guard let track = playback.transportState.track else { return }
            presentationRow = importService.songPresentationRow(for: track)
            let metadata = await importService.songMetadata(videoID: track.youTubeId)
            guard !Task.isCancelled, playback.transportState.track?.id == track.id else { return }
            songMetadata = metadata
        }
        .onExitCommand {
            guard acceptsGlobalKeyEvents, !chaptersPresented else { return }
            handleEscape()
        }
        .onKeyPress(.space) {
            guard acceptsGlobalKeyEvents, !chaptersPresented, !volumePresented else { return .ignored }
            playback.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            guard acceptsGlobalKeyEvents, !chaptersPresented else { return .ignored }
            handleEscape()
            return .handled
        }
        .onAppear {
            rememberedAudibleVolume = NowPlayingVolumePolicy.rememberedAudibleVolume(
                current: playback.volume,
                previous: rememberedAudibleVolume
            )
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if isPresented, volumeEscapePending, event.keyCode == 53 {
                    dismissVolumeForEscape(event.timestamp)
                    return nil
                }
                if event.keyCode == 53, event.timestamp == lastVolumeEscapeTimestamp { return nil }
                if isPresented, chaptersPresented, event.keyCode == 53,
                   event.window?.identifier == MusesSingleInstance.mainWindowIdentifier {
                    chaptersPresented = false
                    return nil
                }
                guard acceptsGlobalKeyEvents, !chaptersPresented,
                      event.window?.identifier == MusesSingleInstance.mainWindowIdentifier else { return event }
                if event.keyCode == 53 {
                    isPresented = false
                    return nil
                }
                return event
            }
        }
        .onChange(of: playback.state.track?.id) {
            seeking = false
            chaptersPresented = false
        }
        .onChange(of: volumePresented) { _, presented in
            if !presented, NSApp.currentEvent?.type == .leftMouseDown {
                volumeEscapePending = false
            }
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

    /// A native popover and its parent can both receive cancellation for the same key event.
    private func dismissVolumeForEscape(_ timestamp: TimeInterval? = nil) {
        lastVolumeEscapeTimestamp = timestamp ?? NSApp.currentEvent?.timestamp
        volumePresented = false
        volumeEscapePending = false
        volumeEscapeHandled = true
        DispatchQueue.main.async { volumeEscapeHandled = false }
    }

    private func handleEscape() {
        if volumeEscapePending { dismissVolumeForEscape() }
        else if volumeEscapeHandled { return }
        else if let event = NSApp.currentEvent, event.timestamp == lastVolumeEscapeTimestamp { return }
        else { isPresented = false }
    }

    private var acceptsGlobalKeyEvents: Bool {
        NowPlayingInputPolicy.acceptsGlobalKeyEvents(nowPlayingPresented: isPresented)
            && ContentKeyboardScope.acceptsShortcuts
            && !lyricsInteractionPresented
    }

    private func splitContent(_ layout: NowPlayingLayout) -> some View {
        HStack(alignment: .center, spacing: layout.columnGap) {
            leftColumn(layout)
                .frame(width: layout.stageSide)

            LyricsView(layout: .leading)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: layout.contentWidth)
        .frame(maxHeight: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stackedContent(_ layout: NowPlayingLayout) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                leftColumn(layout)
                    .frame(width: layout.stageSide)

                LyricsView(layout: .immersiveCentered)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 200)
        }
        .scrollIndicators(.hidden)
    }

    private func leftColumn(_ layout: NowPlayingLayout, centered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                centerContent(size: layout.artworkSlotSide, scale: layout.artworkScale)
            }
            .frame(width: layout.stageSide, height: layout.stageSide)

            trackIdentity(centered: centered)
                .padding(.top, NowPlayingLayout.artworkIdentityGap)

        }
        .frame(width: layout.stageSide)
    }

    private func playbackDock(width: CGFloat) -> some View {
        MusesGlassGroup {
            VStack(spacing: 8) {
                seekRow
                if playback.state.track?.mediaKind == .podcastEpisode {
                    podcastControls
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        RepeatPlaybackButton(hit: 34, iconSize: 14)
                        transportRow.frame(width: 300)
                        volumePopoverButton
                    }
                    VStack(spacing: 8) {
                        transportRow
                        HStack {
                            RepeatPlaybackButton(hit: 34, iconSize: 14)
                            Spacer()
                            volumePopoverButton
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(width: width)
            .musesGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), role: .artworkControl)
            .blocksWindowDrag()
        }
    }

    private var volumePopoverButton: some View {
        Button {
            volumeEscapePending = !volumePresented
            volumePresented.toggle()
        } label: {
            Image(systemName: playback.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(MusesTypography.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.musesTransport)
        .help(tr("Volume", "音量"))
        .accessibilityLabel(tr("Volume", "音量"))
        .accessibilityValue("\(Int((playback.volume * 100).rounded()))%")
        .overlay(alignment: .bottomTrailing) {
            if volumePresented {
                FloatingVolumePanel(width: 330, height: 60, style: .dots) { dismissVolumeForEscape() }
                    .preferredColorScheme(.dark)
                    .offset(y: -44)
            }
        }
    }

    private var lyricsToggle: some View {
        Button { showLyrics.toggle() } label: {
            Image(systemName: "quote.bubble")
                .font(MusesTypography.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottom) {
                    if showLyrics { Circle().fill(BrandColors.accent).frame(width: 4, height: 4) }
                }
        }
        .buttonStyle(.musesTransport(selected: showLyrics))
        .help(tr("Show lyrics", "显示歌词"))
        .accessibilityLabel(tr("Show lyrics", "显示歌词"))
        .accessibilityValue(showLyrics ? tr("On", "开") : tr("Off", "关"))
    }

    @ViewBuilder private func trackIdentity(centered: Bool = false) -> some View {
        if centered {
            VStack(spacing: 12) {
                identityText(centered: true)
                HStack(spacing: 10) { likeButton; moreMenu }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 10) {
                identityText(centered: false)
                Spacer(minLength: 8)
                likeButton
                moreMenu
            }
            .frame(minHeight: 48, alignment: .top)
        }
    }

    private func identityText(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 3) {
            Text(songInformation?.title ?? "—")
                .font(MusesTypography.song(size: 20, emphasized: true, text: songInformation?.title ?? ""))
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(2)
            Text(subtitleLine)
                .font(MusesTypography.song(size: 14))
                .foregroundStyle(BrandColors.textPrimary.opacity(0.7))
                .lineLimit(1)
        }
        .multilineTextAlignment(centered ? .center : .leading)
    }

    private var moreMenu: some View {
        ChromeIconMenu(systemName: "ellipsis", title: tr("More playback actions", "更多播放操作")) {
            Button(tr("Play Next", "下一首播放")) {
                if let track = playback.state.track { playback.queue.playNext(track) }
            }
            Button(tr("Add to Queue", "加入队列")) {
                if let track = playback.state.track { playback.queue.addToQueue(track) }
            }
            if let videoID = playback.state.track?.youTubeId,
               let url = URL(string: "https://youtu.be/\(videoID)") {
                Divider()
                Button(tr("Chapters", "章节", zhHant: "章節"), systemImage: "list.bullet.rectangle") {
                    chaptersPresented = true
                }
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
        }
        .disabled(playback.state.track == nil)
        .help(tr("More", "更多"))
        .accessibilityLabel(tr("More playback actions", "更多播放操作"))
        .popover(isPresented: $chaptersPresented) {
            if let videoID = playback.state.track?.youTubeId {
                YouTubeChaptersView(videoID: videoID) { position in
                    guard playback.state.track?.youTubeId == videoID else { return }
                    playback.seek(to: position)
                    chaptersPresented = false
                }
            }
        }
    }

    private var likeButton: some View {
        let _ = library.likedRevision
        let liked = playback.state.track.map { library.isLiked(id: $0.id) } ?? false
        return Button {
            if let id = playback.state.track?.id { library.toggleLike(id: id) }
        } label: {
            Image(systemName: liked ? "star.fill" : "star")
                .font(MusesTypography.system(size: 13, weight: .semibold))
                .foregroundStyle(liked ? BrandColors.accent : BrandColors.textPrimary.opacity(0.85))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.musesTransport(selected: liked))
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
            .tint(BrandColors.playback)
            .focusEffectDisabled()
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
                        .font(MusesTypography.system(size: 10, weight: .medium))
                        .foregroundStyle(BrandColors.textPrimary.opacity(0.42))
                }
            }
            .font(MusesTypography.system(size: 11, weight: .regular).monospacedDigit())
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
                        .font(MusesTypography.system(size: 22, weight: .semibold))
                        .foregroundStyle(BrandColors.playback)
                        .offset(x: playback.state.isPlaying ? 0 : 1)
                        .frame(width: 44, height: 44)
                        .background(Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.fullAreaPlain)
                .modifier(PlaybackCoreSurface())
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

            lyricsToggle
        }
        .frame(height: 40)
    }

    private var podcastControls: some View {
        HStack(spacing: 18) {
            Button {
                playback.skipPodcast(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .help(tr("Back 15 seconds", "后退 15 秒", zhHant: "倒退 15 秒"))
            .accessibilityLabel(tr("Back 15 seconds", "后退 15 秒", zhHant: "倒退 15 秒"))
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button(String(format: "%g×", rate)) {
                        playback.setPodcastPlaybackRate(Float(rate))
                    }
                }
            } label: {
                Text(String(format: "%g×", playback.podcastPlaybackRate))
                    .monospacedDigit()
            }
            .help(tr("Playback Speed", "播放速度", zhHant: "播放速度"))
            .accessibilityLabel(tr("Playback Speed", "播放速度", zhHant: "播放速度"))
            Button {
                playback.skipPodcast(by: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .help(tr("Forward 15 seconds", "前进 15 秒", zhHant: "前進 15 秒"))
            .accessibilityLabel(tr("Forward 15 seconds", "前进 15 秒", zhHant: "前進 15 秒"))
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        systemName: String,
        selected: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(MusesTypography.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? BrandColors.accent : BrandColors.textPrimary.opacity(0.85))
                .selectionHalo(selected)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.musesTransport(selected: selected))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(selected ? tr("On", "开启") : tr("Off", "关闭"))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(MusesTypography.system(size: 34, weight: .regular))
                .foregroundStyle(BrandColors.textSecondary)
                .accessibilityHidden(true)
            Text(tr("Nothing Playing", "暂无播放"))
                .font(MusesTypography.title3.weight(.semibold))
                .foregroundStyle(BrandColors.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var displayedPosition: Double {
        seeking ? seekValue : playback.state.position
    }

    private var subtitleLine: String {
        guard let information = songInformation else { return " " }
        if !information.album.isEmpty {
            return "\(information.artist) — \(information.album)"
        }
        return information.artist
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
