import SwiftUI

/// 歌词视图:滚动对齐当前播放行(spec §7.4)。
///
/// 替换阶段 2 的 `LyricsPlaceholderView`。从 `LyricsService` 获取歌词,
/// 按 `playback.state.position` 高亮当前行并自动滚动。
struct LyricsView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var currentLineIndex: Int?

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
    private func lyricsList(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: false)) { timeline in
            let position = playback.state.position
            let idx = Self.currentLineIndex(in: lines, at: position)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            Text(line.text)
                                .font(i == idx ? .title3 : .body)
                                .fontWeight(i == idx ? .bold : .regular)
                                .foregroundStyle(i == idx ? BrandColors.magenta : BrandColors.textSecondary)
                                .id(line.id)
                                .animation(.easeInOut(duration: 0.2), value: idx)
                        }
                    }
                    .padding(.vertical, 20)
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
        .padding(.vertical, 16)
    }

    /// 无歌词占位(沿用阶段 2 文案)。
    private var placeholder: some View {
        VStack(spacing: 8) {
            Text("无可用歌词").font(.title3).foregroundStyle(BrandColors.textPrimary)
            Text("歌词将在播放时自动从 LRCLIB 或本地 .lrc 加载")
                .font(.callout).foregroundStyle(BrandColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// 加载当前曲目的歌词(曲目变化时重新加载)。
    /// 缓存优先:TrackSnapshot.lyrics 命中则直接解析,跳过网络。
    private func loadLyrics() {
        guard let track = playback.state.track else {
            lines = nil; loadedTrackId = nil; return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        lines = nil

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

    /// 将 LyricsResult 解析为 LyricLine 数组并更新 lines。
    private func applyLyrics(_ result: LyricsResult) {
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

    /// 计算当前位置对应的歌词行索引(最近一行 time <= position)。
    /// 纯函数,便于单元测试。
    static func currentLineIndex(in lines: [LyricLine], at position: Double) -> Int? {
        var best: Int? = nil
        for (i, line) in lines.enumerated() {
            guard let t = line.time else { continue }
            if t <= position {
                best = i
            } else {
                break // 已排序,后续更大
            }
        }
        return best
    }
}