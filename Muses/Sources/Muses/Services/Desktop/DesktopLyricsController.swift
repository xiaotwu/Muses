import SwiftUI
import AppKit

/// 桌面歌词悬浮层(Final Spec §10.1 Feature 1 — desktop/floating lyrics overlay)。
///
/// 无边框常驻置顶 `NSPanel`,承载 `DesktopLyricsOverlayView`。复用同一 `LyricsService` 与
/// `LyricsView.currentLineIndex` 活跃行计算(SwiftUI `TimelineView.animation` 驱动,
/// 无第二计时器)。功能开关 `PrefKey.ffDesktopLyrics`(默认关):关 → 隐藏并释放 panel。
@MainActor
final class DesktopLyricsController {
    private var panel: NSPanel?
    private(set) var revision: Int = 0

    init() {}

    /// 开关同步:启用 → 创建并显示 panel;禁用 → 释放。幂等。
    func setEnabled(_ enabled: Bool, playback: PlaybackService, library: LibraryService,
                    lyrics: LyricsService) {
        if enabled {
            if panel == nil { panel = makePanel() }
            let host = NSHostingView(rootView:
                DesktopLyricsOverlayView()
                    .environment(playback)
                    .environment(library)
                    .environment(lyrics))
            panel?.contentView = host
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
        revision &+= 1
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 700, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("MusesDesktopLyrics")
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// 桌面歌词内容视图:大字号当前行,半透明背景,可拖动(panel 级)。
/// 复用 `LyricsView.currentLineIndex` 与 `LyricsService` 加载逻辑(单一计时引擎)。
struct DesktopLyricsOverlayView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var lrcOffsetMs: Int = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playback.state.isPlaying)) { _ in
            content
        }
        .background(
            Color.black.opacity(0.35)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .onAppear { loadLyrics() }
        .onChange(of: playback.state.track?.id) { _, _ in loadLyrics() }
    }

    private var content: some View {
        let offset = Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0
        let position = playback.state.position
        let idx = lines.flatMap { LyricsView.currentLineIndex(in: $0, at: position, offset: offset) }
        let text = idx.flatMap { i in lines?[safe: i]?.text } ?? tr("No lyrics", "无歌词")
        return Text(text)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }

    private func loadLyrics() {
        guard let track = playback.state.track else {
            lines = nil; loadedTrackId = nil; lrcOffsetMs = 0; return
        }
        guard track.id != loadedTrackId else { return }
        loadedTrackId = track.id
        lines = nil
        service.manualOffsetMs = track.lyricsOffsetMs ?? 0
        if let cached = service.fetchCached(track: track) { apply(cached); return }
        Task {
            if let r = await service.fetch(track: track) { apply(r) }
        }
    }

    private func apply(_ result: LyricsResult) {
        lrcOffsetMs = result.offsetMs ?? 0
        if let synced = result.syncedLyrics, !synced.isEmpty {
            lines = LyricsService.parseLRC(synced)
        } else if let plain = result.plainLyrics, !plain.isEmpty {
            lines = plain.split(separator: "\n").map {
                LyricLine(id: UUID(), time: nil, text: String($0))
            }
        } else { lines = nil }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}