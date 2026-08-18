import SwiftUI

/// 歌词视图:滚动对齐当前播放行(spec §7.4 / Phase 22 §10.8 扩展)。
///
/// Phase 22 扩展:
/// - 点击定时行 → `seek(to: line.time + offset)`(click-to-seek)。
/// - 偏移:手动逐曲 `Track.lyricsOffsetMs` + LRC `[offset:]` 自动偏移,二者相加(秒)。
///   偏移同时作用于当前行检测与点击跳转,保持一致。
/// - 逐词高亮:增强 LRC 的 `<mm:ss.xx>` 内联标签解析为 `LyricWord`,当前行内逐词高亮;
///   无逐词数据回退到行级高亮;无时间标签回退到纯文本。回退链 word→line→plain,绝不伪造。
struct LyricsView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var currentLineIndex: Int?
    /// LRC `[offset:]` 自动偏移(毫秒),随歌词加载固定。手动偏移实时读 `service.manualOffsetMs`。
    @State private var lrcOffsetMs: Int = 0

    /// 有效偏移(秒)= 手动(@Observable,实时)+ LRC 自动。
    private var offsetSeconds: Double { Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0 }

    var body: some View {
        Group {
            if let lines, !lines.isEmpty {
                lyricsList(lines)
            } else {
                placeholder
            }
        }
        .onAppear { loadLyrics() }
        .onChange(of: playback.state.track?.id) { loadLyrics() }
    }

    /// 歌词列表:TimelineView 按动画刷新,高亮当前行并滚动对齐。
    /// Apple Music 风格:当前行加大加粗(magenta),邻行随距离渐隐,文本居中。
    /// 当前行若有逐词时间,则行内逐词高亮当前词;否则行级高亮。
    private func lyricsList(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: false)) { timeline in
            let position = playback.state.position
            let idx = Self.currentLineIndex(in: lines, at: position, offset: offsetSeconds)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            let distance = abs((idx ?? 0) - i)
                            Group {
                                if i == idx, let words = line.words, line.time != nil {
                                    wordRow(words: words, position: position)
                                } else {
                                    Text(line.text)
                                        .font(i == idx ? .title2 : .body)
                                        .fontWeight(i == idx ? .bold : .regular)
                                        .foregroundStyle(i == idx ? BrandColors.magenta : BrandColors.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .opacity(i == idx ? 1.0 : (idx == nil ? 1.0 : max(0.35, 1.0 - Double(distance) * 0.16)))
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.2), value: idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let t = line.time else { return }
                                playback.seek(to: t + offsetSeconds)
                            }
                            .help(line.time != nil ? tr("Jump to this line", "跳转到此行") : "")
                        }
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: idx) { _, newIdx in
                    if let newIdx, newIdx < lines.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lines[newIdx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// 逐词行:将当前行的 `LyricWord` 序列渲染为单行内联文本,高亮当前位置所在的词。
    private func wordRow(words: [LyricWord], position: Double) -> some View {
        let activeWord = Self.currentWordIndex(in: words, at: position, offset: offsetSeconds)
        return HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.element.id) { wi, w in
                Text(w.text)
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(wi == activeWord ? BrandColors.magenta : BrandColors.textPrimary.opacity(0.55))
            }
        }
        .multilineTextAlignment(.center)
    }

    /// 无歌词占位(沿用阶段 2 文案)。
    private var placeholder: some View {
        VStack(spacing: 8) {
            Text(tr("No lyrics available", "无可用歌词")).font(.title3).foregroundStyle(BrandColors.textPrimary)
            Text(tr("Lyrics will load automatically from LRCLIB or local .lrc files during playback", "歌词将在播放时自动从 LRCLIB 或本地 .lrc 加载"))
                .font(.callout).foregroundStyle(BrandColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
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

        Task {
            let result = await service.fetch(track: track)
            if let result { applyLyrics(result) }
        }
    }

    /// 将 LyricsResult 解析为 LyricLine 数组并更新 lines;记录 LRC 自动偏移。
    private func applyLyrics(_ result: LyricsResult) {
        lrcOffsetMs = result.offsetMs ?? 0
        if let synced = result.syncedLyrics, !synced.isEmpty {
            lines = LyricsService.parseLRC(synced)
        } else if let plain = result.plainLyrics, !plain.isEmpty {
            // 无时间标签的纯文本歌词
            lines = plain.split(separator: "\n").map {
                LyricLine(id: UUID(), time: nil, text: String($0))
            }
        } else {
            lines = nil
        }
    }

    /// 计算当前位置对应的歌词行索引(最近一行 time+offset <= position)。
    /// 偏移默认 0,保持与既有测试兼容。纯函数,便于单元测试。
    static func currentLineIndex(in lines: [LyricLine], at position: Double, offset: Double = 0) -> Int? {
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
    static func currentWordIndex(in words: [LyricWord], at position: Double, offset: Double = 0) -> Int? {
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