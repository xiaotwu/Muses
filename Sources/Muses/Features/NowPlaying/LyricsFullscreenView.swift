import SwiftUI
import AppKit

/// Full-screen lyrics presentation:
/// - `.lyricsOnly`: a centered, large-type scrolling list with tap-to-seek lines
///   and word-level highlighting (fallback chain word -> line -> plain).
/// - `.minimal`: only the current line, centered and extra-large, no scrolling;
///   falls back to the first line when no timed lines exist.
///
/// Reuses `LyricsService` for loading/parsing and `LyricsView`'s pure-function
/// timing logic, keeping the rendering layer separate so it can support both
/// the big-type full-screen and single-line minimal styles. Offsets match
/// `LyricsView` (per-track manual + LRC `[offset:]`, in seconds).
struct LyricsFullscreenView: View {
    let mode: NowPlayingLyricsMode
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var lrcOffsetMs: Int = 0
    @FocusState private var focusedLineID: UUID?
    @FocusState private var minimalLineFocused: Bool

    /// Effective offset (seconds) = manual (@Observable, live) + LRC automatic.
    private var offsetSeconds: Double { Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0 }
    private var prioritizeLegibility: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var body: some View {
        Group {
            if let lines, !lines.isEmpty {
                content(lines)
            } else {
                Text(tr("No lyrics available", "无可用歌词"))
                    .font(.title3).foregroundStyle(BrandColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: playback.state.track?.id) { load() }
    }

    @ViewBuilder
    private func content(_ lines: [LyricLine]) -> some View {
        switch mode {
        case .lyricsOnly: lyricsOnlyList(lines)
        case .minimal:    minimalSingleLine(lines)
        case .inline:      EmptyView() // This view should never be reached in inline mode
        }
    }

    // MARK: - lyricsOnly: centered large-type scrolling list

    private func lyricsOnlyList(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1,
                                paused: !playback.state.isPlaying || reduceMotion)) { _ in
            let position = playback.state.position
            let idx = LyricsView.currentLineIndex(in: lines, at: position, offset: offsetSeconds)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            Group {
                                if i == idx, let words = line.words, line.time != nil {
                                    wordRow(words: words, position: position)
                                } else {
                                    Text(line.text)
                                        .font(i == idx
                                            ? .system(size: 40, weight: .bold)
                                            : .title3)
                                        .fontWeight(i == idx ? .bold : .regular)
                                        .foregroundStyle(i == idx ? Color.white : BrandColors.textSecondary)
                                        .multilineTextAlignment(.center)
                                        .currentLyricLaserIfNeeded(i == idx)
                                }
                            }
                            .id(line.id)
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
                    .padding(.vertical, 48)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: idx) { _, newIdx in
                    if let newIdx, newIdx < lines.count {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lines[newIdx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wordRow(words: [LyricWord], position: Double) -> some View {
        let activeWord = LyricsView.currentWordIndex(in: words, at: position, offset: offsetSeconds)
        return HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.element.id) { wi, w in
                Text(w.text)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(
                        Color.white.opacity(activeWord == nil || wi == activeWord ? 1 : 0.68)
                    )
            }
        }
        .multilineTextAlignment(.center)
        .currentLyricLaser()
    }

    // MARK: - minimal: current line only

    private func minimalSingleLine(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1,
                                paused: !playback.state.isPlaying || reduceMotion)) { _ in
            let position = playback.state.position
            let idx = LyricsView.currentLineIndex(in: lines, at: position, offset: offsetSeconds)
            let line = (idx.map { lines[$0] }) ?? lines.first
            Text(line?.text ?? "")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Color.white)
                .currentLyricLaser()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let t = line?.time { playback.seek(to: t + offsetSeconds) }
                }
                .focusable(line?.time != nil)
                .focusEffectDisabled()
                .focused($minimalLineFocused)
                .lyricKeyboardFocusHalo(
                    minimalLineFocused,
                    prioritizeLegibility: prioritizeLegibility
                )
                .onKeyPress(.return) {
                    guard let t = line?.time else { return .ignored }
                    playback.seek(to: t + offsetSeconds)
                    return .handled
                }
                .accessibilityAddTraits(line?.time == nil ? [] : .isButton)
                .accessibilityHint(line?.time == nil
                    ? ""
                    : tr("Jump to this lyric", "跳转到这句歌词"))
                .id(line?.id)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: idx)
        }
    }

    // MARK: - Loading (cache-first plus offset accumulation, matching LyricsView)

    private func load() {
        guard let track = playback.state.track else {
            lines = nil; loadedTrackId = nil; lrcOffsetMs = 0; return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        lines = nil
        service.manualOffsetMs = track.lyricsOffsetMs ?? 0
        if let cached = service.fetchCached(track: track) {
            apply(cached)
            return
        }
        let expectedTrackID = track.id
        Task {
            if let result = await service.fetch(track: track),
               loadedTrackId == expectedTrackID,
               playback.state.track?.id == expectedTrackID {
                apply(result)
            }
        }
    }

    private func apply(_ result: LyricsResult) {
        lrcOffsetMs = result.offsetMs ?? 0
        if let synced = result.syncedLyrics, !synced.isEmpty {
            lines = LyricsService.parseLRC(synced)
        } else if let plain = result.plainLyrics, !plain.isEmpty {
            lines = plain.split(separator: "\n").map { LyricLine(id: UUID(), time: nil, text: String($0)) }
        } else {
            lines = nil
        }
    }
}

/// Per-track lyrics offset fine-tuning: ±50ms steps, persisted to
/// `Track.lyricsOffsetMs`. Shows the current effective offset (including the
/// LRC automatic offset). The reset button clears the manual offset.
struct LyricsOffsetStepper: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    private let step = 50

    /// Reads the observable manual offset live (@Observable; updates instantly
    /// after an adjustment).
    private var currentMs: Int { service.manualOffsetMs }

    var body: some View {
        let _ = service.manualOffsetMs // Registers the @Observable dependency
        HStack(spacing: 4) {
            Image(systemName: "timer").font(.caption).foregroundStyle(BrandColors.textSecondary)
            Button { adjust(-step) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered).controlSize(.mini)
            Text(offsetLabel).font(.caption2).monospacedDigit()
                .foregroundStyle(BrandColors.textSecondary).frame(width: 54)
            Button { adjust(step) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered).controlSize(.mini)
            if currentMs != 0 {
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .help(tr("Reset offset", "重置偏移"))
            }
        }
        .help(tr("Lyrics offset (ms)", "歌词偏移(毫秒)"))
    }

    private var offsetLabel: String {
        let v = currentMs
        return v == 0 ? "0ms" : String(format: "%+dms", v)
    }

    private func adjust(_ delta: Int) {
        guard let tid = playback.state.track?.id else { return }
        service.setOffset(trackId: tid, offsetMs: currentMs + delta)
    }

    private func reset() {
        guard let tid = playback.state.track?.id else { return }
        service.setOffset(trackId: tid, offsetMs: 0)
    }
}
