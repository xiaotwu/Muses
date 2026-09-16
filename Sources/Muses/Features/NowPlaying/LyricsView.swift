import SwiftUI
import AppKit

struct LyricsInteractionPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Lyrics view: scrolls to keep the currently playing line aligned.
///
/// Extensions:
/// - Clicking a timed line triggers `seek(to: line.time + offset)` (click-to-seek).
/// - Offset: the per-track manual `Track.lyricsOffsetMs` plus the LRC
///   `[offset:]` automatic offset, summed (in seconds). The same offset applies
///   to both current-line detection and click-to-seek so they stay consistent.
/// - Word-level highlighting: enhanced-LRC `<mm:ss.xx>` inline tags are parsed
///   into `LyricWord`s so the current word is highlighted inside the current
///   line; without word data it falls back to line-level highlighting, and
///   without time tags to plain text. The fallback chain is word -> line ->
///   plain — timings are never fabricated.
enum LyricsLayout: Equatable {
    case centered
    case leading
    case fullscreen

    var alignment: Alignment { self == .leading ? .leading : .center }
    var textAlignment: TextAlignment { self == .leading ? .leading : .center }
    var isImmersive: Bool { self == .leading }
}

/// Pure distance styling keeps the lyric hierarchy deterministic and testable.
enum LyricsVisualStyle {
    static func opacity(distance: Int, isCurrent: Bool,
                        immersive: Bool, prioritizeLegibility: Bool) -> Double {
        if isCurrent { return 1 }
        if !immersive { return max(0.35, 1 - Double(distance) * 0.16) }
        let value = max(0.18, 0.56 - Double(max(0, distance - 1)) * 0.11)
        return prioritizeLegibility ? max(0.56, value) : value
    }

    static func blurRadius(distance: Int, isCurrent: Bool,
                           immersive: Bool, prioritizeLegibility: Bool) -> CGFloat {
        guard immersive, !isCurrent, !prioritizeLegibility else { return 0 }
        return min(2.8, 0.7 + CGFloat(max(0, distance - 1)) * 0.72)
    }
}

private struct LyricPaletteKey: EnvironmentKey {
    static let defaultValue: [Color] = [BrandColors.textPrimary]
}

extension EnvironmentValues {
    var lyricPalette: [Color] {
        get { self[LyricPaletteKey.self] }
        set { self[LyricPaletteKey.self] = newValue }
    }
}

/// Static artwork-derived colors; timing and word emphasis retain their existing behavior.
struct CurrentLyricAccentModifier: ViewModifier {
    @Environment(\.lyricPalette) private var colors
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.foregroundStyle(LinearGradient(
            colors: contrast == .increased ? [BrandColors.textPrimary] : colors,
            startPoint: .leading, endPoint: .trailing))
    }
}

struct LyricKeyboardFocusHaloModifier: ViewModifier {
    let isFocused: Bool
    let prioritizeLegibility: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        BrandColors.textPrimary.opacity(prioritizeLegibility ? 0.96 : 0.82),
                        lineWidth: prioritizeLegibility ? 2 : 1
                    )

                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func currentLyricAccent() -> some View {
        modifier(CurrentLyricAccentModifier())
    }

    @ViewBuilder
    func currentLyricAccentIfNeeded(_ isCurrent: Bool) -> some View {
        if isCurrent {
            currentLyricAccent()
        } else {
            self
        }
    }

    func lyricKeyboardFocusHalo(
        _ isFocused: Bool,
        prioritizeLegibility: Bool
    ) -> some View {
        modifier(LyricKeyboardFocusHaloModifier(
            isFocused: isFocused,
            prioritizeLegibility: prioritizeLegibility
        ))
    }
}

struct LyricsView: View {
    var layout: LyricsLayout = .centered
    var showsCurrentLineOnly = false
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var artworkHues: [[Double]] = []
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var originalTexts: [String] = []
    @State private var documentKey = ""
    @State private var source: LyricsSource?
    @State private var loading = false
    @State private var processingMessage: String?
    @State private var showMatches = false
    @AppStorage(PrefKey.nowPlayingLyricsMode) private var displayMode = NowPlayingLyricsMode.inline.rawValue
    @AppStorage(PrefKey.lyricsTranslationLanguage) private var translationTarget = "off"
    @AppStorage(PrefKey.lyricsRomanization) private var showRomanization = false
    @AppStorage(PrefKey.lyricsSource) private var provider = "lrclib"
    @AppStorage(PrefKey.lyricsIntelligence) private var intelligentMatching = true

    private var loadKey: String {
        [playback.transportState.track?.id.uuidString ?? "", provider, String(service.selectionRevision), String(intelligentMatching)].joined(separator: ":")
    }

    @FocusState private var focusedLineID: UUID?
    /// The LRC `[offset:]` automatic offset (milliseconds), fixed once the lyrics
    /// load. The manual offset is read live from `service.manualOffsetMs`.
    @State private var lrcOffsetMs: Int = 0

    /// Effective offset (seconds) = manual (@Observable, live) + LRC automatic.
    private var offsetSeconds: Double { Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0 }
    @State private var showTiming = false
    private var prioritizeLegibility: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if loading { ProgressView().controlSize(.small) }
                if let lines, !lines.isEmpty, !lines.contains(where: { $0.time != nil }) {
                    Image(systemName: "clock.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .help(tr("No timing data. Use Match Lyrics to choose a synchronized version.",
                                 "此版本没有时间轴，可通过匹配歌词选择同步版本。", zhHant: "此版本沒有時間軸，可透過配對歌詞選擇同步版本。"))
                        .accessibilityLabel(tr("Unsynced lyrics", "非同步歌词", zhHant: "非同步歌詞"))
                }
                if translationTarget != "off", lines?.contains(where: { $0.translation != nil }) == true {
                    Text(tr("Machine translation", "机器翻译")).font(.caption2).foregroundStyle(.secondary)
                }
                if showRomanization, lines?.contains(where: { $0.romanization != nil }) == true {
                    Text(tr("Auto romanization", "自动音译")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if lines?.contains(where: { $0.time != nil }) == true {
                    Button { showTiming.toggle() } label: {
                        Image(systemName: "timer").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Adjust lyric timing", "调整歌词时间", zhHant: "調整歌詞時間"))
                    .accessibilityLabel(tr("Adjust lyric timing", "调整歌词时间", zhHant: "調整歌詞時間"))
                    .popover(isPresented: $showTiming) { timingControls }
                }
                if let processingMessage {
                    Image(systemName: "info.circle").help(processingMessage)
                        .accessibilityLabel(processingMessage)
                }
                Menu {
                    if layout != .centered {
                        Picker(tr("Lyrics display", "歌词显示", zhHant: "歌詞顯示"), selection: $displayMode) {
                            Text(tr("With artwork", "封面与歌词", zhHant: "封面與歌詞")).tag(NowPlayingLyricsMode.inline.rawValue)
                            Text(tr("Lyrics only", "仅歌词", zhHant: "僅歌詞")).tag(NowPlayingLyricsMode.lyricsOnly.rawValue)
                            Text(tr("Current line", "当前行", zhHant: "目前歌詞行")).tag(NowPlayingLyricsMode.minimal.rawValue)
                        }
                        Divider()
                    }
                    if let source {
                        Text(source == .cached ? tr("Source: lyrics stored with this track", "来源：此曲目保存的歌词", zhHant: "來源：此曲目儲存的歌詞") : tr("Source: ", "来源：", zhHant: "來源：") + (source == .lrclib ? "LRCLIB" : "Musixmatch"))
                        Divider()
                    }
                    LyricsTranslationPicker(selection: $translationTarget)
                    Toggle(tr("Romanization", "音译"), isOn: $showRomanization)
                    Divider()
                    Button(tr("Match Lyrics…", "匹配歌词…")) { showMatches = true }
                        .disabled(playback.transportState.track == nil)
                    Button(tr("Lyrics Settings…", "歌词设置…")) {
                        NotificationCenter.default.post(name: .musesOpenSettings, object: SettingsCategory.lyrics)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(tr("Lyrics options", "歌词选项"))
                .accessibilityLabel(tr("Lyrics options", "歌词选项"))
            }
            if let lines, !lines.isEmpty {
                if showsCurrentLineOnly && lines.contains(where: { $0.time != nil }) {
                    currentLineOnly(lines)
                } else { lyricsList(lines) }
            }
            else { placeholder }
        }
        .environment(\.lyricPalette, artworkHues.isEmpty ? [BrandColors.textPrimary] : artworkHues.map {
            Color(hue: $0[0], saturation: min($0[1], 0.72), brightness: colorScheme == .dark ? max(0.82, $0[2]) : min(0.42, $0[2]))
        })
        .task(id: playback.transportState.track?.id) {
            artworkHues = []
            let expected = playback.transportState.track?.id
            let source = ArtworkSource.resolve(for: playback.transportState.track)
            let values = await Task.detached(priority: .utility) { () -> [[Double]] in
                guard let image = source.loadNSImage() else { return [] }
                return AlbumArtworkExtractor.dominantColors(image, count: 5).compactMap {
                    guard let color = $0.usingColorSpace(.deviceRGB) else { return nil }
                    return [Double(color.hueComponent), Double(color.saturationComponent), Double(color.brightnessComponent)]
                }
            }.value
            guard !Task.isCancelled, playback.transportState.track?.id == expected else { return }
            artworkHues = values
        }
        .task(id: loadKey) { await loadLyrics() }
        .task(id: documentKey + String(showRomanization)) { await loadRomanization() }
        .onChange(of: translationTarget) { _, _ in
            updateEnrichment(translations: nil, romanizations: nil, clearTranslation: true)
            processingMessage = nil
        }
        .background { translationBridge }
        .preference(key: LyricsInteractionPresentedKey.self, value: showTiming || showMatches)
        .sheet(isPresented: $showMatches) {
            if let track = playback.transportState.track { LyricsMatchPicker(track: track).id(track.id) }
        }
    }

    private var timingControls: some View {
        VStack(spacing: 12) {
            Text(tr("Lyric timing", "歌词时间", zhHant: "歌詞時間")).font(.headline)
            HStack(spacing: 16) {
                Button { adjustTiming(by: -500) } label: { Image(systemName: "minus") }
                    .help(tr("Show lyrics 0.5 seconds earlier", "歌词提前 0.5 秒", zhHant: "歌詞提前 0.5 秒"))
                    .accessibilityLabel(tr("Show lyrics 0.5 seconds earlier", "歌词提前 0.5 秒", zhHant: "歌詞提前 0.5 秒"))
                    .disabled(service.manualOffsetMs <= -30_000)
                Text(String(format: "%+.1f s", Double(service.manualOffsetMs) / 1000))
                    .monospacedDigit().frame(minWidth: 64)
                Button { adjustTiming(by: 500) } label: { Image(systemName: "plus") }
                    .help(tr("Show lyrics 0.5 seconds later", "歌词延后 0.5 秒", zhHant: "歌詞延後 0.5 秒"))
                    .accessibilityLabel(tr("Show lyrics 0.5 seconds later", "歌词延后 0.5 秒", zhHant: "歌詞延後 0.5 秒"))
                    .disabled(service.manualOffsetMs >= 30_000)
                Button { adjustTiming(by: -service.manualOffsetMs) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(tr("Reset lyric timing", "重置歌词时间", zhHant: "重設歌詞時間"))
                    .accessibilityLabel(tr("Reset lyric timing", "重置歌词时间", zhHant: "重設歌詞時間"))
                    .disabled(service.manualOffsetMs == 0)
            }
        }
        .padding(16)
    }

    private func adjustTiming(by delta: Int) {
        guard let track = playback.transportState.track else { return }
        if !service.setOffset(for: track, offsetMs: max(-30_000, min(30_000, service.manualOffsetMs + delta))) {
            processingMessage = tr("Could not save lyric timing. Try again.", "无法保存歌词时间，请重试。", zhHant: "無法儲存歌詞時間，請重試。")
        }
    }

    @ViewBuilder
    private var translationBridge: some View {
        if #available(macOS 15.0, *), translationTarget != "off", !originalTexts.isEmpty {
            let expectedKey = documentKey
            let expectedTarget = translationTarget
            LyricsTranslationBridge(lines: originalTexts, target: translationTarget) { translated, message in
                guard documentKey == expectedKey, translationTarget == expectedTarget,
                      loadedTrackId == playback.transportState.track?.id else { return }
                updateEnrichment(translations: translated, romanizations: nil, clearTranslation: true)
                processingMessage = message
            }
            .id(documentKey + translationTarget)
        }
    }

    private func updateEnrichment(translations: [String]?, romanizations: [String]?,
                                  clearTranslation: Bool = false, clearRomanization: Bool = false) {
        guard let current = lines else { return }
        lines = current.enumerated().map { index, line in
            LyricLine(id: line.id, time: line.time, text: line.text, words: line.words,
                      translation: translations?.count == current.count ? translations?[index] : (clearTranslation ? nil : line.translation),
                      romanization: romanizations?.count == current.count ? romanizations?[index] : (clearRomanization ? nil : line.romanization))
        }
    }

    private func loadRomanization() async {
        updateEnrichment(translations: nil, romanizations: nil, clearRomanization: true)
        guard showRomanization, !originalTexts.isEmpty else { return }
        guard LyricsIntelligence.availability == .available else {
            processingMessage = LyricsIntelligence.availability.message
            return
        }
        let expectedKey = documentKey
        let key = LyricsDocumentIdentity.digest(["romanization"] + originalTexts)
        if let cached = service.enrichment(key: key) {
            updateEnrichment(translations: nil, romanizations: cached)
            return
        }
        do {
            let romanized = try await LyricsIntelligence.romanize(originalTexts)
            guard !Task.isCancelled, documentKey == expectedKey, showRomanization,
                  loadedTrackId == playback.transportState.track?.id else { return }
            service.rememberEnrichment(romanized, key: key)
            updateEnrichment(translations: nil, romanizations: romanized)
        } catch {
            guard !Task.isCancelled, documentKey == expectedKey else { return }
            processingMessage = tr("Romanization unavailable. Original lyrics are still shown.", "音译暂不可用，仍显示原文歌词。")
        }
    }

    /// The lyrics list: TimelineView refreshes on animation ticks, highlights the
    /// current line, and scrolls to keep it aligned. Apple Music style: the
    /// current line is white, larger and bold; neighboring lines fade with
    /// distance; text is centered. When the current line has word timings, the
    /// active word is highlighted within it; otherwise the whole line is.
    private func lyricsList(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1,
                                paused: !playback.transportState.isPlaying)) { _ in
            let position = playback.transportState.position
            let idx = Self.currentLineIndex(in: lines, at: position, offset: offsetSeconds)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: layout.isImmersive ? 42 : 20) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            let distance = abs((idx ?? 0) - i)
                            let isCurrent = i == idx
                            lyricRow(line, isCurrent: isCurrent, position: position)
                            .opacity(idx == nil
                                ? 1
                                : LyricsVisualStyle.opacity(
                                    distance: distance,
                                    isCurrent: isCurrent,
                                    immersive: layout.isImmersive,
                                    prioritizeLegibility: prioritizeLegibility
                                ))
                            .blur(radius: idx == nil ? 0 : LyricsVisualStyle.blurRadius(
                                distance: distance,
                                isCurrent: isCurrent,
                                immersive: layout.isImmersive,
                                prioritizeLegibility: prioritizeLegibility
                            ))
                            .id(line.id)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let t = line.time else { return }
                                playback.seek(to: t + offsetSeconds)
                            }
                            .focusable(line.time != nil)
                            .focusEffectDisabled()
                            .focused($focusedLineID, equals: line.id)
                            .lyricKeyboardFocusHalo(
                                focusedLineID == line.id,
                                prioritizeLegibility: prioritizeLegibility
                            )
                            .onKeyPress(.return) {
                                guard let t = line.time else { return .ignored }
                                playback.seek(to: t + offsetSeconds)
                                return .handled
                            }
                            .accessibilityAddTraits(line.time == nil ? [] : .isButton)
                            .accessibilityHint(line.time == nil
                                ? ""
                                : tr("Jump to this lyric", "跳转到这句歌词"))
                            .help(line.time != nil ? tr("Jump to this line", "跳转到此行") : "")
                        }
                    }
                    .padding(.vertical, layout.isImmersive ? 72 : 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .onChange(of: idx, initial: true) { _, newIdx in
                    if let newIdx, newIdx < lines.count {
                        if reduceMotion {
                            proxy.scrollTo(lines[newIdx].id, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(lines[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, layout.isImmersive ? 0 : 8)
    }

    @ViewBuilder
    private func lyricRow(_ line: LyricLine, isCurrent: Bool, position: Double) -> some View {
        VStack(alignment: layout == .leading ? .leading : .center,
               spacing: layout.isImmersive ? 4 : 2) {
            if isCurrent, let words = line.words, line.time != nil {
                wordRow(words: words, position: position)
            } else {
                Text(line.text)
                    .font(lineFont(isCurrent: isCurrent))
                    .fontWeight(isCurrent ? .bold : (layout.isImmersive ? .medium : .regular))
                    .multilineTextAlignment(layout.textAlignment)
                    .frame(maxWidth: .infinity, alignment: layout.alignment)
                    .currentLyricAccentIfNeeded(isCurrent)
            }

            if let romanization = line.romanization, !romanization.isEmpty {
                Text(romanization)
                    .font(.system(size: layout.isImmersive ? 14 : 12))
                    .foregroundStyle(BrandColors.textSecondary)
                    .multilineTextAlignment(layout.textAlignment)
                    .frame(maxWidth: .infinity, alignment: layout.alignment)
            }
            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: layout.isImmersive ? 13 : 11,
                                  weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent
                        ? BrandColors.textPrimary.opacity(0.84)
                        : BrandColors.textPrimary.opacity(0.72))
                    .multilineTextAlignment(layout.textAlignment)
                    .frame(maxWidth: .infinity, alignment: layout.alignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: layout.alignment)
    }

    private func currentLineOnly(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playback.transportState.isPlaying)) { _ in
            let position = playback.transportState.position
            if let index = Self.currentLineIndex(in: lines, at: position, offset: offsetSeconds) {
                Button {
                    if let time = lines[index].time { playback.seek(to: time + offsetSeconds) }
                } label: { lyricRow(lines[index], isCurrent: true, position: position) }
                .buttonStyle(.plain)
                .help(tr("Jump to this lyric", "跳转到这句歌词"))
            } else {
                Text(tr("Lyrics begin soon", "歌词即将开始", zhHant: "歌詞即將開始"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lineFont(isCurrent: Bool) -> Font {
        if layout == .fullscreen { return .system(size: isCurrent ? 40 : 26, weight: isCurrent ? .bold : .regular) }
        if layout.isImmersive {
            return .system(size: isCurrent ? 34 : 26,
                           weight: isCurrent ? .bold : .medium)
        }
        return isCurrent ? .title2 : .body
    }

    /// Word-level row: renders the current line's `LyricWord` sequence as one
    /// inline row of text, highlighting the word at the current position.
    private func wordRow(words: [LyricWord], position: Double) -> some View {
        let activeWord = Self.currentWordIndex(in: words, at: position, offset: offsetSeconds)
        return HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.element.id) { wi, w in
                Text(w.text)
                    .font(layout.isImmersive
                        ? .system(size: 34, weight: .bold)
                        : .title2.bold())
                    .opacity(activeWord == nil || wi == activeWord ? 1 : 0.68)
            }
        }
        .frame(maxWidth: .infinity, alignment: layout.alignment)
        .multilineTextAlignment(layout.textAlignment)
        .currentLyricAccent()
    }

    /// Empty lyrics: quiet, Demus / Better Lyrics style. No instructional copy.
    private var placeholder: some View {
        Text(tr("No lyrics available", "无可用歌词"))
            .font(.title3)
            .foregroundStyle(BrandColors.textSecondary.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: layout.alignment)
            .padding(.vertical, 16)
    }

    /// Loads lyrics for the current track (reloading whenever the track changes).
    /// Cache first, then network. Also computes the effective offset =
    /// per-track manual offset + LRC automatic offset (seconds).
    private func loadLyrics() async {
        lines = nil; source = nil; originalTexts = []; documentKey = ""; processingMessage = nil
        guard let track = playback.transportState.track else {
            loadedTrackId = nil; lrcOffsetMs = 0; loading = false; return
        }
        loadedTrackId = track.id
        loading = true
        service.prepareOffset(for: track)
        let result = await service.load(track: track)
        guard !Task.isCancelled, playback.transportState.track?.id == track.id else { return }
        loading = false
        if let result { applyLyrics(result) }
    }

    /// Parses the LyricsResult into a `[LyricLine]` and updates `lines`;
    /// records the LRC automatic offset.
    private func applyLyrics(_ result: LyricsResult) {
        lrcOffsetMs = result.offsetMs ?? 0
        var parsed: [LyricLine]
        if let synced = result.syncedLyrics, !synced.isEmpty {
            parsed = LyricsService.parseLRC(synced)
        } else if let plain = result.plainLyrics, !plain.isEmpty {
            // Plain-text lyrics without time tags.
            parsed = plain.split(separator: "\n").map {
                LyricLine(id: UUID(), time: nil, text: String($0))
            }
        } else {
            lines = nil
            return
        }

        if translationTarget != "off",
           let translated = result.translations?.first(where: { $0.language == translationTarget })?.lines,
           translated.count == parsed.count {
            parsed = zip(parsed, translated).map { line, translation in
                LyricLine(
                    id: line.id,
                    time: line.time,
                    text: line.text,
                    words: line.words,
                    translation: translation
                )
            }
        }
        lines = parsed
        source = result.source
        originalTexts = parsed.map { $0.text.replacingOccurrences(of: #"<\d+:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression) }
        documentKey = LyricsDocumentIdentity.digest([loadedTrackId?.uuidString ?? ""] + originalTexts)
    }

    /// Computes the index of the lyric line for the current position (the last
    /// line whose time+offset <= position). The offset defaults to 0 for
    /// compatibility with existing tests. Pure function, easy to unit test.
    nonisolated static func currentLineIndex(in lines: [LyricLine], at position: Double,
                                              offset: Double = 0) -> Int? {
        var best: Int? = nil
        for (i, line) in lines.enumerated() {
            guard let t = line.time else { continue }
            if t + offset <= position {
                best = i
            } else {
                break // Lines are sorted; the rest are later.
            }
        }
        return best
    }

    /// Computes the index of the active word in the current line (the last word
    /// whose start+offset <= position). nil when there are no word timings.
    nonisolated static func currentWordIndex(in words: [LyricWord], at position: Double,
                                              offset: Double = 0) -> Int? {
        var best: Int? = nil
        for (i, w) in words.enumerated() {
            if w.start + offset <= position {
                best = i
            } else {
                break
            }
        }
        return best
    }
}
