import SwiftUI
import WebKit
import AppKit

/// YouTube watch/embed helpers. Native audio stays on yt-dlp; this surface is
/// the official iframe for picture, opened on demand so we do not double-play.
enum YouTubeEmbed {
    static func isVideo(_ track: TrackSnapshot?) -> Bool {
        guard let id = track?.youTubeId, !id.isEmpty else { return false }
        return true
    }

    static func thumbnailURL(videoId: String) -> URL? {
        YouTubeThumbnail.url(videoId: videoId)
    }

    static func watchURL(videoId: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }

    static func pageHTML(videoId: String, start: VideoPlaybackStart = .init(), sessionID: UUID? = nil) -> String {
        let id = videoId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let startSeconds = String(format: "%.0f", start.position.rounded(.down))
        return """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;background:#000;height:100%;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
        </style></head><body>
        <iframe id="player" src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=0&start=\(startSeconds)&rel=0&playsinline=1&enablejsapi=1&origin=https%3A%2F%2Fwww.youtube-nocookie.com"
                allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        <script>
        let playerSession = '\(sessionID?.uuidString ?? "")';
        let expectedVideo = '\(id)';
        let player, ticker, stopped = false, initialized = false, lastVolume;
        let volumeSync = {revision: 0, target: null, deadline: 0};
        let seekSync = {revision: 0, target: null, deadline: 0};
        function report(kind, extra = {}) {
          if (stopped || !playerSession) return;
          window.webkit.messageHandlers.musesVideo.postMessage({session: playerSession, kind, ...extra});
        }
        function sample() {
          if (stopped || !player || !player.getPlayerState) return;
          const actual = player.getVideoData().video_id;
          if (actual && actual !== expectedVideo) {
            player.pauseVideo(); report('error'); return;
          }
          if (initialized) {
            const volume = player.isMuted() ? 0 : player.getVolume();
            const waiting = volumeSync.target !== null && Math.abs(volume - volumeSync.target) > 1
                            && performance.now() < volumeSync.deadline;
            if (!waiting) {
              volumeSync.target = null;
              if (volume !== lastVolume) {
                lastVolume = volume; report('volume', {volume, revision: volumeSync.revision});
              }
            }
          }
          const position = player.getCurrentTime();
          const awaitingSeek = seekSync.target !== null && Math.abs(position - seekSync.target) > 2
                               && performance.now() < seekSync.deadline;
          if (!awaitingSeek) seekSync.target = null;
          report('state', {position, positionRevision: awaitingSeek ? -1 : seekSync.revision,
                          duration: player.getDuration(),
                          playerState: player.getPlayerState()});
        }
        window.musesVideoCommand = function(command) {
          if (stopped || !player) return;
          if (command.name === 'volume' || command.name === 'initialize') {
            volumeSync.revision = command.volumeRevision;
            volumeSync.target = command.name === 'volume' ? command.value : command.volume;
            volumeSync.deadline = performance.now() + 2000;
          }
          if (command.name === 'seek' || command.name === 'initialize') {
            seekSync.revision = command.seekRevision;
            seekSync.target = command.name === 'seek' ? command.value : command.position;
            seekSync.deadline = performance.now() + 2000;
          }
          switch(command.name) {
            case 'initialize':
              player[command.volume > 0 ? 'unMute' : 'mute']();
              player.setVolume(command.volume);
              initialized = true;
              player[command.play ? 'loadVideoById' : 'cueVideoById']({
                videoId: expectedVideo, startSeconds: command.position
              }); break;
            case 'play': player.playVideo(); break;
            case 'pause': player.pauseVideo(); break;
            case 'seek': player.seekTo(command.value, true); break;
            case 'volume': player[command.value > 0 ? 'unMute' : 'mute'](); player.setVolume(command.value); break;
          }
        };
        window.musesStopVideo = function() {
          stopped = true; clearInterval(ticker);
          if (player && player.pauseVideo) player.pauseVideo();
        };
        function onYouTubeIframeAPIReady() {
          if (stopped) return;
          player = new YT.Player('player', {events: {
            onReady: function(event) {
              if (stopped) { event.target.pauseVideo(); return; }
              if (playerSession) {
                report('ready');
                ticker = setInterval(sample, 250);
              } else {
                const player = event.target;
                player.\(start.volumePercent > 0 ? "unMute" : "mute")();
                player.setVolume(\(start.volumePercent));
                player.\(start.shouldPlay ? "loadVideoById" : "cueVideoById")({
                  videoId: expectedVideo, startSeconds: \(start.position)
                });
              }
            },
            onStateChange: sample,
            onError: function() { report('error'); },
            onAutoplayBlocked: function() { report('blocked'); }
          }});
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}

/// Full-window YouTube iframe. Pauses native yt-dlp audio while open so
/// picture and sound come from one player.
struct YouTubeVideoOverlay: View {
    let videoId: String
    @Binding var isPresented: Bool
    @Environment(PlaybackService.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.resumeAfterVideo) private var resumePref = true
    @State private var videoSession: VideoPlaybackSession?
    @State private var escapeMonitor: Any?
    @State private var closeHovered = false
    @State private var chaptersPresented = false
    @State private var closeKeyboardRevealed = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = VideoOverlayLayout.videoSize(in: geometry.size)
            ZStack {
                BrandColors.scrim
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                ZStack {
                    if let videoSession {
                        Group {
                            if let surface = videoSession.surface { YouTubeWKEmbed(surface: surface) }
                        }
                        .allowsHitTesting(videoSession.ready && videoSession.state.error == nil)
                        if !videoSession.ready, videoSession.state.error == nil {
                            ProgressView().tint(.white)
                                .accessibilityLabel(tr("Loading video", "正在加载视频", zhHant: "正在載入影片"))
                        }
                        if videoSession.state.error != nil {
                            Text(tr("Video unavailable. Close to return to audio.",
                                    "视频暂不可用，关闭后返回音频。", zhHant: "影片暫不可用，關閉後返回音訊。"))
                                .font(.callout)
                                .foregroundStyle(.white)
                                .padding(24)
                        }
                    } else {
                        Color.black
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    let revealed = closeHovered || closeKeyboardRevealed || closeFocused || chaptersPresented || NSWorkspace.shared.isVoiceOverEnabled
                    ZStack {
                        VideoCloseHoverRegion(isHovered: $closeHovered)
                        ChromeIconButton(
                            systemName: "xmark",
                            help: tr("Close", "关闭"),
                            accessibility: tr("Close video", "关闭视频"),
                            action: close
                        )
                        .focused($closeFocused)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : -8)
                        .allowsHitTesting(revealed)
                        ChromeIconButton(
                            systemName: "arrow.up.left.and.arrow.down.right",
                            help: tr("Floating video window", "悬浮视频窗口", zhHant: "浮動影片視窗"),
                            accessibility: tr("Floating video window", "悬浮视频窗口", zhHant: "浮動影片視窗"),
                            action: {
                                videoSession?.surface?.float()
                                isPresented = false
                            }
                        )
                        .offset(x: -48)
                        .opacity(revealed ? 1 : 0)
                        .allowsHitTesting(revealed)
                        .disabled(videoSession?.ready != true || videoSession?.state.error != nil)
                        ChromeIconButton(
                            systemName: "list.bullet.rectangle",
                            help: tr("Chapters", "章节", zhHant: "章節"),
                            accessibility: tr("Chapters", "章节", zhHant: "章節"),
                            action: { chaptersPresented = true }
                        )
                        .offset(x: 48)
                        .opacity(revealed ? 1 : 0)
                        .allowsHitTesting(revealed)
                        .disabled(videoSession?.ready != true || videoSession?.state.error != nil)
                        .popover(isPresented: $chaptersPresented) {
                            YouTubeChaptersView(videoID: videoId) { position in
                                guard let videoSession, !videoSession.closing,
                                      videoSession.videoId == videoId else { return }
                                playback.seek(to: position)
                                chaptersPresented = false
                            }
                        }
                    }
                    .frame(width: 160, height: 56)
                    .contentShape(Rectangle())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: revealed)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            if videoSession == nil {
                let session: VideoPlaybackSession
                if let existing = playback.videoSession, existing.videoId == videoId, !existing.closing {
                    session = existing
                } else {
                    session = playback.beginVideoSession(videoId: videoId)
                }
                if session.surface == nil {
                    session.surface = VideoSurface(session: session, playback: playback, resume: resumePref)
                }
                session.surface?.onPresentationClosed = close
                session.surface?.dock()
                videoSession = session
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if chaptersPresented {
                    if event.keyCode == 53 {
                        chaptersPresented = false
                        return nil
                    }
                    return event
                }
                if event.keyCode == 48, !closeKeyboardRevealed {
                    closeKeyboardRevealed = true
                    closeFocused = true
                    return nil
                }
                if event.keyCode == 36, closeFocused {
                    close()
                    return nil
                }
                if event.keyCode == 53 {
                    close()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
        .onChange(of: videoId) { _, _ in
            // A new track must capture its own position and intent on a fresh
            // opening; never apply the previous video's start offset to it.
            close()
        }
        .onExitCommand { close() }
        .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: isPresented)
    }

    private func close() {
        videoSession?.surface?.close()
        isPresented = false
    }
}

struct YouTubeWKEmbed: NSViewRepresentable {
    let surface: VideoSurface
    var floating = false

    final class PlayerCoordinator: NSObject, WKScriptMessageHandler {
        weak var session: VideoPlaybackSession?
        weak var webView: WKWebView?
        var onStopped: (() -> Void)?
        var readyTimeout: Task<Void, Never>?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let session, !session.closing,
                  let body = message.body as? [String: Any],
                  body["session"] as? String == session.id.uuidString else { return }
            switch body["kind"] as? String {
            case "ready":
                readyTimeout?.cancel()
                session.didBecomeReady()
            case "state":
                guard let position = body["position"] as? Double,
                      let duration = body["duration"] as? Double,
                      let playerState = body["playerState"] as? Int else { return }
                guard let positionRevision = body["positionRevision"] as? Int else { return }
                session.receive(position: position, duration: duration, playerState: playerState,
                                positionRevision: positionRevision)
            case "volume":
                if let volume = body["volume"] as? Double, let revision = body["revision"] as? Int {
                    session.receiveVolume(percent: volume, revision: revision)
                }
            case "error": session.fail()
            case "blocked": session.setPlaying(false)
            default: break
            }
        }

        func send(_ name: String, value: Double?) {
            guard let session, !session.closing else { return }
            var command: [String: Any] = ["name": name, "volumeRevision": session.volumeRevision, "seekRevision": session.seekRevision]
            if name == "initialize" {
                command["position"] = session.state.position
                command["volume"] = Double(session.volume) * 100
                command["play"] = session.requestedPlay
            }
            if let value { command["value"] = value }
            guard let data = try? JSONSerialization.data(withJSONObject: command),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.musesVideoCommand(\(json))", completionHandler: nil)
        }

        var videoId: String?
        var navigationGeneration: UInt64 = 0

        func beginNavigation(to nextVideoId: String) -> UInt64? {
            guard videoId != nextVideoId else { return nil }
            videoId = nextVideoId
            navigationGeneration &+= 1
            return navigationGeneration
        }

        func invalidate() {
            navigationGeneration &+= 1
            videoId = nil
        }

        func owns(videoId: String, generation: UInt64) -> Bool {
            self.videoId == videoId && navigationGeneration == generation
        }
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        surface.attach(to: host, floating: floating)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        surface.attach(to: host, floating: floating)
    }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        // Only detach this host's contents. A replacement host may already own the player.
        host.subviews.forEach { $0.removeFromSuperview() }
    }

    static func makePlayer(session: VideoPlaybackSession,
                           onStopped: @escaping () -> Void) -> (WKWebView, PlayerCoordinator) {
        let coordinator = PlayerCoordinator()
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(coordinator, name: "musesVideo")
        let view = WKWebView(frame: .zero, configuration: config)
        coordinator.webView = view
        coordinator.session = session
        coordinator.onStopped = onStopped
        coordinator.readyTimeout = Task { @MainActor [weak session] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let session, !session.ready else { return }
            session.fail()
        }
        session.sendCommand = { [weak coordinator] name, value in coordinator?.send(name, value: value) }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        _ = coordinator.beginNavigation(to: session.videoId)
        view.loadHTMLString(YouTubeEmbed.pageHTML(videoId: session.videoId,
                            start: session.initialStart, sessionID: session.id),
                            baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return (view, coordinator)
    }

    static func stopPlayer(_ view: WKWebView, coordinator: PlayerCoordinator) {
        coordinator.invalidate()
        coordinator.readyTimeout?.cancel()
        coordinator.readyTimeout = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "musesVideo")
        view.evaluateJavaScript("window.musesStopVideo && window.musesStopVideo()") { _, _ in
            // Native audio may resume only after WebKit acknowledges stopping all media.
            view.pauseAllMediaPlayback {
                view.stopLoading()
                view.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
                coordinator.onStopped?()
                coordinator.onStopped = nil
                coordinator.webView = nil
            }
        }
    }


}

/// Fit both dimensions before centering, including short desktop windows.
enum VideoOverlayLayout {
    static func videoSize(in available: CGSize) -> CGSize {
        let width = min(1100, max(0, available.width - 48))
        let height = min(width * 9 / 16, max(0, available.height - 48))
        return CGSize(width: height * 16 / 9, height: height)
    }

}

/// Tracks the small reveal region above WebKit without intercepting video input.
private struct VideoCloseHoverRegion: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> HoverView { HoverView() }

    func updateNSView(_ view: HoverView, context: Context) {
        view.onHover = { isHovered = $0 }
    }

    static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.stopTracking() }

    final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?
        private var monitor: Any?
        private var lastInside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopTracking()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                let inside = event.window === window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if inside != self.lastInside {
                    self.lastInside = inside
                    self.onHover?(inside)
                }
                return event
            }
        }

        func stopTracking() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
