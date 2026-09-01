import SwiftUI
import AppKit

/// 歌词视图:滚动对齐当前播放行(spec §7.4 / Phase 22 §10.8 扩展)。
///
/// Phase 22 扩展:
/// - 点击定时行 → `seek(to: line.time + offset)`(click-to-seek)。
/// - 偏移:手动逐曲 `Track.lyricsOffsetMs` + LRC `[offset:]` 自动偏移,二者相加(秒)。
///   偏移同时作用于当前行检测与点击跳转,保持一致。
/// - 逐词高亮:增强 LRC 的 `<mm:ss.xx>` 内联标签解析为 `LyricWord`,当前行内逐词高亮;
///   无逐词数据回退到行级高亮;无时间标签回退到纯文本。回退链 word→line→plain,绝不伪造。
enum LyricsLayout: Equatable {
    case centered
    case leading

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

/// Shared treatment for the current lyric across inline and fullscreen modes.
/// The white glyph/outline remains when accessibility asks us to remove the
/// colored bloom; cyan and violet only provide a restrained laser edge.
struct CurrentLyricLaserModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var allowsColoredBloom: Bool {
        !reduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.white)
            // A compact white outline survives both accessibility fallbacks.
            .shadow(color: .white.opacity(0.92), radius: 0, x: -0.65)
            .shadow(color: .white.opacity(0.92), radius: 0, x: 0.65)
            .shadow(color: .white.opacity(0.76), radius: 0, y: -0.55)
            .shadow(color: .white.opacity(0.76), radius: 0, y: 0.55)
            // Chromatic edges are semantic emphasis, never the text fill.
            .shadow(
                color: allowsColoredBloom
                    ? Color(red: 0.30, green: 0.91, blue: 1.00).opacity(0.68)
                    : .clear,
                radius: 0.45,
                x: -0.8
            )
            .shadow(
                color: allowsColoredBloom
                    ? Color(red: 0.68, green: 0.48, blue: 1.00).opacity(0.62)
                    : .clear,
                radius: 0.45,
                x: 0.8
            )
            .shadow(
                color: allowsColoredBloom
                    ? Color(red: 0.35, green: 0.79, blue: 1.00).opacity(0.20)
                    : .white.opacity(0.16),
                radius: allowsColoredBloom ? 6 : 1.5
            )
            .shadow(
                color: allowsColoredBloom
                    ? Color(red: 0.65, green: 0.42, blue: 1.00).opacity(0.14)
                    : .clear,
                radius: 10
            )
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
                        Color.white.opacity(prioritizeLegibility ? 0.96 : 0.82),
                        lineWidth: prioritizeLegibility ? 2 : 1
                    )
                    .shadow(color: .white.opacity(0.20), radius: 4)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func currentLyricLaser() -> some View {
        modifier(CurrentLyricLaserModifier())
    }

    @ViewBuilder
    func currentLyricLaserIfNeeded(_ isCurrent: Bool) -> some View {
        if isCurrent {
            currentLyricLaser()
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
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @FocusState private var focusedLineID: UUID?
    /// LRC `[offset:]` 自动偏移(毫秒),随歌词加载固定。手动偏移实时读 `service.manualOffsetMs`。
    @State private var lrcOffsetMs: Int = 0

    /// 有效偏移(秒)= 手动(@Observable,实时)+ LRC 自动。
    private var offsetSeconds: Double { Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0 }
    private var prioritizeLegibility: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    var body: some View {
        Group {
            if let lines, !lines.isEmpty {
                lyricsList(lines)
            } else {
                placeholder
            }
        }
        .onAppear { loadLyrics() }
        .onChange(of: playback.state.track?.id) { _, _ in loadLyrics() }
    }

    /// 歌词列表:TimelineView 按动画刷新,高亮当前行并滚动对齐。
    /// Apple Music 风格:当前行白色加大加粗,邻行随距离渐隐,文本居中。
    /// 当前行若有逐词时间,则行内逐词高亮当前词;否则行级高亮。
    private func lyricsList(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1,
                                paused: !playback.state.isPlaying || reduceMotion)) { _ in
            let position = playback.state.position
            let idx = Self.currentLineIndex(in: lines, at: position, offset: offsetSeconds)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: layout.isImmersive ? 28 : 10) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            let distance = abs((idx ?? 0) - i)
                            let isCurrent = i == idx
                            lyricRow(line, isCurrent: isCurrent, position: position)
                            .opacity(idx == nil
                                ? (layout.isImmersive ? 0.56 : 1)
                                : LyricsVisualStyle.opacity(
                                    distance: distance,
                                    isCurrent: isCurrent,
                                    immersive: layout.isImmersive,
                                    prioritizeLegibility: prioritizeLegibility
                                ))
                            .blur(radius: LyricsVisualStyle.blurRadius(
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
                    .foregroundStyle(isCurrent ? Color.white : BrandColors.textPrimary)
                    .multilineTextAlignment(layout.textAlignment)
                    .frame(maxWidth: .infinity, alignment: layout.alignment)
                    .currentLyricLaserIfNeeded(isCurrent)
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

    private func lineFont(isCurrent: Bool) -> Font {
        if layout.isImmersive {
            return .system(size: isCurrent ? 34 : 26,
                           weight: isCurrent ? .bold : .medium)
        }
        return isCurrent ? .title2 : .body
    }

    /// 逐词行:将当前行的 `LyricWord` 序列渲染为单行内联文本,高亮当前位置所在的词。
    private func wordRow(words: [LyricWord], position: Double) -> some View {
        let activeWord = Self.currentWordIndex(in: words, at: position, offset: offsetSeconds)
        return HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.element.id) { wi, w in
                Text(w.text)
                    .font(layout.isImmersive
                        ? .system(size: 34, weight: .bold)
                        : .title2.bold())
                    .foregroundStyle(
                        Color.white.opacity(activeWord == nil || wi == activeWord ? 1 : 0.68)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: layout.alignment)
        .multilineTextAlignment(layout.textAlignment)
        .currentLyricLaser()
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

    /// 加载当前曲目的歌词(曲目变化时重新加载)。缓存优先,再联网。
    /// 同时计算有效偏移 = 手动逐曲偏移 + LRC 自动偏移(秒)。
    private func loadLyrics() {
        guard let track = playback.state.track else {
            lines = nil; loadedTrackId = nil; lrcOffsetMs = 0; return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        lines = nil
        // 初始化可观察手动偏移(从持久化快照),供微调器与渲染共用。
        service.manualOffsetMs = track.lyricsOffsetMs ?? 0

        // 缓存命中:直接解析,不联网
        if let cached = service.fetchCached(track: track) {
            applyLyrics(cached)
            return
        }

        let expectedTrackID = track.id
        Task {
            let result = await service.fetch(track: track)
            guard loadedTrackId == expectedTrackID,
                  playback.state.track?.id == expectedTrackID else { return }
            if let result { applyLyrics(result) }
        }
    }

    /// 将 LyricsResult 解析为 LyricLine 数组并更新 lines;记录 LRC 自动偏移。
    private func applyLyrics(_ result: LyricsResult) {
        lrcOffsetMs = result.offsetMs ?? 0
        var parsed: [LyricLine]
        if let synced = result.syncedLyrics, !synced.isEmpty {
            parsed = LyricsService.parseLRC(synced)
        } else if let plain = result.plainLyrics, !plain.isEmpty {
            // 无时间标签的纯文本歌词
            parsed = plain.split(separator: "\n").map {
                LyricLine(id: UUID(), time: nil, text: String($0))
            }
        } else {
            lines = nil
            return
        }

        if let translated = result.translations?.first?.lines,
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
    }

    /// 计算当前位置对应的歌词行索引(最近一行 time+offset <= position)。
    /// 偏移默认 0,保持与既有测试兼容。纯函数,便于单元测试。
    nonisolated static func currentLineIndex(in lines: [LyricLine], at position: Double,
                                              offset: Double = 0) -> Int? {
        var best: Int? = nil
        for (i, line) in lines.enumerated() {
            guard let t = line.time else { continue }
            if t + offset <= position {
                best = i
            } else {
                break // 已排序,后续更大
            }
        }
        return best
    }

    /// 计算当前行内活跃词索引(最近一词 start+offset <= position)。无逐词时间为 nil。
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
