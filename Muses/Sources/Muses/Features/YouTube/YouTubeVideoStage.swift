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

    static func pageHTML(videoId: String) -> String {
        let id = videoId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;background:#000;height:100%;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}
        </style></head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&rel=0&modestbranding=1&playsinline=1&enablejsapi=1"
                allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
    }
}

/// Compact 16:9 peek below the transport. Click or drag up expands the embed.
struct YouTubeVideoWell: View {
    let videoId: String
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(BrandColors.textPrimary.opacity(0.28))
                .frame(width: 36, height: 4)
            Button(action: onExpand) {
                ZStack {
                    CachedAsyncImage(
                        url: YouTubeEmbed.thumbnailURL(videoId: videoId),
                        content: { $0.resizable().scaledToFill() },
                        placeholder: {
                            Rectangle().fill(BrandColors.surface)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    YouTubeMark(size: 22)
                        .shadow(radius: 6)
                        .accessibilityHidden(true)
                }
                .frame(height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BrandColors.textPrimary.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -36 { onExpand() }
                }
        )
        .help(tr("Swipe up or click to play video", "上划或点击播放视频"))
        .accessibilityLabel(tr("Open YouTube video", "打开 YouTube 视频"))
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
    @State private var playbackSuspension: UUID?
    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            BrandColors.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 12) {
                HStack {
                    Text(tr("Video", "视频"))
                        .font(.headline)
                        .foregroundStyle(BrandColors.textPrimary)
                    Spacer()
                    ChromeIconButton(
                        systemName: "xmark",
                        help: tr("Close", "关闭"),
                        accessibility: tr("Close video", "关闭视频"),
                        action: close
                    )
                }
                YouTubeWKEmbed(videoId: videoId)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 960)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .musesFloatingChrome(cornerRadius: 18)
        }
        .onAppear {
            if playbackSuspension == nil {
                // Suspension is independent of the instantaneous engine flag:
                // a desired play may still be buffering when the overlay opens.
                playbackSuspension = playback.beginNativePlaybackSuspension()
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            if let token = playbackSuspension {
                playbackSuspension = nil
                let shouldResume = resumePref
                // Give dismantleNSView's explicit iframe pause/blank navigation
                // a short head start so native audio cannot overlap WebKit tail.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    playback.endNativePlaybackSuspension(token, resume: shouldResume)
                }
            }
        }
        .onExitCommand { close() }
        .animation(MusesMotion.overlayAnimation(reduceMotion: reduceMotion), value: isPresented)
    }

    private func close() { isPresented = false }
}

struct YouTubeWKEmbed: NSViewRepresentable {
    let videoId: String

    final class Coordinator {
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        _ = context.coordinator.beginNavigation(to: videoId)
        view.loadHTMLString(YouTubeEmbed.pageHTML(videoId: videoId),
                            baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let generation = context.coordinator.beginNavigation(to: videoId) else { return }
        Self.pauseIframe(in: nsView) {
            guard context.coordinator.owns(videoId: videoId,
                                           generation: generation) else { return }
            nsView.loadHTMLString(
                YouTubeEmbed.pageHTML(videoId: videoId),
                baseURL: URL(string: "https://www.youtube-nocookie.com")
            )
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // The video WebView is deliberately separate from native audio. End its
        // media lifetime explicitly so a retained WebKit process cannot keep an
        // untracked soundtrack alive after the overlay disappears.
        coordinator.invalidate()
        pauseIframe(in: nsView) {
            nsView.stopLoading()
            nsView.loadHTMLString(
                "<!doctype html><html><body style='margin:0;background:#000'></body></html>",
                baseURL: nil
            )
        }
    }

    private static func pauseIframe(in webView: WKWebView,
                                    completion: @escaping () -> Void) {
        let script = """
        (() => {
          const frame = document.querySelector('iframe');
          if (frame && frame.contentWindow) {
            frame.contentWindow.postMessage(JSON.stringify({
              event: 'command', func: 'pauseVideo', args: []
            }), '*');
          }
          document.querySelectorAll('video, audio').forEach(media => media.pause());
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in completion() }
    }
}
