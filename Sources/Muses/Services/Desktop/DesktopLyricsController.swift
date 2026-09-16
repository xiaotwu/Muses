import SwiftUI
import AppKit

/// Desktop floating lyrics overlay (Final Spec §10.1 Feature 1 — desktop/floating lyrics overlay).
///
/// A borderless, always-on-top `NSPanel` hosting `DesktopLyricsOverlayView`. It reuses the same
/// `LyricsService` and the `LyricsView.currentLineIndex` active-line calculation (driven by
/// SwiftUI `TimelineView.animation`, so there is no second timer). Feature flag
/// `PrefKey.ffDesktopLyrics` (off by default): off → hides and releases the panel.
@MainActor
final class DesktopLyricsController {
    private var panel: NSPanel?
    private(set) var revision: Int = 0

    init() {}

    /// Toggles the overlay: enabled → create and show the panel; disabled → release it. Idempotent.
    func setEnabled(_ enabled: Bool, playback: PlaybackService, library: LibraryService,
                    lyrics: LyricsService) {
        if enabled {
            if panel == nil {
                let created = makePanel()
                let host = NSHostingView(rootView:
                    DesktopLyricsOverlayView()
                        .environment(playback)
                        .environment(library)
                        .environment(lyrics))
                host.sizingOptions = []
                created.contentView = host
                panel = created
            }
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
        panel.title = tr("Desktop Lyrics", "桌面歌词", zhHant: "桌面歌詞")
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

/// Desktop lyrics content view: the current line in large type over a translucent,
/// draggable background (drag is handled at the panel level). Reuses
/// `LyricsView.currentLineIndex` and `LyricsService` loading logic (single timing engine).
struct DesktopLyricsOverlayView: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LyricsService.self) private var service
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(PrefKey.lyricsSource) private var provider = "lrclib"
    @AppStorage(PrefKey.lyricsIntelligence) private var intelligentMatching = true
    @State private var lines: [LyricLine]?
    @State private var loadedTrackId: UUID?
    @State private var lrcOffsetMs: Int = 0
    @State private var isLoading = false
    @State private var source: LyricsSource?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playback.transportState.isPlaying)) { _ in
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.black.opacity(reduceTransparency ? 1 : 0.72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .task(id: "\(playback.transportState.track?.id.uuidString ?? ""):\(service.selectionRevision):\(provider):\(intelligentMatching)") { await loadLyrics() }
    }

    private var content: some View {
        let offset = Double(service.manualOffsetMs + lrcOffsetMs) / 1000.0
        let position = playback.transportState.position
        let text = Self.displayText(lines: lines, at: position, offset: offset, isLoading: isLoading)
        return Text(text)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(source == nil ? "" : source == .lrclib ? "LRCLIB" : source == .musixmatch ? "Musixmatch" : tr("Saved lyrics", "已保存的歌词"))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }

    static func displayText(lines: [LyricLine]?, at position: Double,
                            offset: Double = 0, isLoading: Bool = false) -> String {
        if isLoading {
            return tr("Loading lyrics…", "正在加载歌词…", zhHant: "正在載入歌詞…")
        }
        guard let lines, !lines.isEmpty else {
            return tr("No lyrics", "无歌词", zhHant: "無歌詞")
        }
        if let index = LyricsView.currentLineIndex(in: lines, at: position, offset: offset) {
            return lines[index].text
        }
        if lines.contains(where: { $0.time != nil }) {
            return tr("Lyrics begin soon", "歌词即将开始", zhHant: "歌詞即將開始")
        }
        return tr("Unsynced lyrics — open Now Playing to read", "非同步歌词，请在正在播放中阅读", zhHant: "非同步歌詞，請在正在播放中閱讀")
    }

    private func loadLyrics() async {
        guard let track = playback.transportState.track else {
            lines = nil; loadedTrackId = nil; lrcOffsetMs = 0; isLoading = false; return
        }
        loadedTrackId = track.id
        lines = nil
        lrcOffsetMs = 0
        isLoading = true
        source = nil
        service.prepareOffset(for: track)
        let result = await service.load(track: track)
        guard !Task.isCancelled, playback.transportState.track?.id == track.id else { return }
        isLoading = false
        if let result { apply(result) }
    }

    private func apply(_ result: LyricsResult) {
        source = result.source
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
