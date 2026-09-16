import AppKit
import SwiftUI
import WebKit

/// Session-owned presentation. Reparenting the view never navigates or creates another player.
@Observable
@MainActor
final class VideoSurface: NSObject, NSWindowDelegate {
    private(set) var isFloating = false
    private(set) var isClosing = false
    let session: VideoPlaybackSession
    @ObservationIgnored private let playerView: NSView
    @ObservationIgnored private let stopPlayer: (@escaping () -> Void) -> Void
    @ObservationIgnored private let resume: Bool
    @ObservationIgnored private let presentsWindow: Bool
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var playback: PlaybackService?
    var onPresentationClosed: (() -> Void)?

    convenience init(session: VideoPlaybackSession, playback: PlaybackService, resume: Bool) {
        let (view, coordinator) = YouTubeWKEmbed.makePlayer(session: session, onStopped: {})
        self.init(session: session, playback: playback, resume: resume, playerView: view,
                  presentsWindow: true) { completion in
            coordinator.onStopped = completion
            YouTubeWKEmbed.stopPlayer(view, coordinator: coordinator)
        }
    }

    /// Injected view and stop acknowledgement allow lifecycle tests without a live WebView.
    init(session: VideoPlaybackSession, playback: PlaybackService, resume: Bool,
         playerView: NSView, presentsWindow: Bool,
         stopPlayer: @escaping (@escaping () -> Void) -> Void) {
        self.session = session
        self.playback = playback
        self.playerView = playerView
        self.stopPlayer = stopPlayer
        self.resume = resume
        self.presentsWindow = presentsWindow
        super.init()
        session.onClose = { [weak self] in self?.close() }
    }

    func attach(to host: NSView, floating: Bool) {
        guard !isClosing, floating == isFloating, playerView.superview !== host else { return }
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: host.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    func float() {
        guard !isClosing, !isFloating, let playback else { return }
        isFloating = true
        guard presentsWindow else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 310),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = tr("Floating Video", "悬浮视频", zhHant: "浮動影片")
        panel.identifier = NSUserInterfaceItemIdentifier("Muses.floating-video")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentMinSize = NSSize(width: 320, height: 220)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingVideoView(surface: self).environment(playback))
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Returning preserves transport, session identity, and the exact WebView instance.
    func dock() {
        guard !isClosing else { return }
        isFloating = false
        releasePanel()
    }

    func returnToMain() {
        guard !isClosing else { return }
        dock()
        MusesSingleInstance.pendingVideoPresentation = true
        MusesSingleInstance.orderFrontMainWindow()
        NotificationCenter.default.post(name: .musesShowYouTubeVideo, object: nil)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        releasePanel()
        session.requestClose()
        onPresentationClosed?()
        onPresentationClosed = nil
        playerView.removeFromSuperview()
        stopPlayer { [weak playback, session, resume] in
            playback?.finishVideoSession(session, resume: resume)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func releasePanel() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }
}

private struct FloatingVideoView: View {
    let surface: VideoSurface
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        VStack(spacing: 0) {
            YouTubeWKEmbed(surface: surface, floating: true)
                .background(.black)
                .overlay {
                    if surface.session.state.error != nil {
                        Text(tr("Video unavailable", "视频暂不可用", zhHant: "影片暫不可用"))
                            .foregroundStyle(.white).padding()
                    }
                }
            HStack {
                Button(action: surface.returnToMain) {
                    Label(tr("Return to main window", "返回主窗口", zhHant: "返回主視窗"),
                          systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Spacer()
                Button { playback.toggle() } label: {
                    Image(systemName: playback.primaryAction.symbol)
                }
                .accessibilityLabel(playback.primaryAction.title)
                Button(action: surface.close) { Image(systemName: "xmark") }
                    .accessibilityLabel(tr("Close video", "关闭视频", zhHant: "關閉影片"))
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.regularMaterial)
        }
        .onExitCommand(perform: surface.close)
    }
}
