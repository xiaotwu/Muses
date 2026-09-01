import AppKit
import SwiftUI

enum YouTubeCatalogLink {
    static func releaseURL(stableID: String) -> URL? {
        if let playlistID = component(after: "playlist:", in: stableID) {
            var components = URLComponents(string: "https://music.youtube.com/playlist")
            components?.queryItems = [URLQueryItem(name: "list", value: playlistID)]
            return components?.url
        }
        if let browseID = component(after: "browse:", in: stableID) {
            return pathURL(component: "browse", identity: browseID)
        }
        return nil
    }

    static func artistURL(stableID: String) -> URL? {
        if let channelID = component(after: "channel:", in: stableID) {
            return pathURL(component: "channel", identity: channelID)
        }
        if let browseID = component(after: "browse:", in: stableID) {
            return pathURL(component: "browse", identity: browseID)
        }
        return nil
    }

    private static func component(after prefix: String, in stableID: String) -> String? {
        guard stableID.hasPrefix(prefix) else { return nil }
        let value = String(stableID.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func pathURL(component: String, identity: String) -> URL? {
        guard let base = URL(string: "https://music.youtube.com") else { return nil }
        return base.appending(path: component).appending(path: identity)
    }
}

private struct CatalogCollectionContextMenu: ViewModifier {
    let tracks: [TrackSnapshot]
    let openTitle: String
    let playTitle: String
    let shuffleTitle: String
    let addTitle: String
    let link: URL?
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(PlaybackService.self) private var playback

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(openTitle, systemImage: "arrow.forward.circle", action: onOpen)
            if !tracks.isEmpty {
                Button(playTitle, systemImage: "play.fill", action: onPlay)
                Button(shuffleTitle, systemImage: "shuffle", action: onShuffle)
                Button(addTitle, systemImage: "text.badge.plus") {
                    tracks.forEach(playback.queue.addToQueue)
                }
            }
            if let link {
                Button(tr("Copy Link", "复制链接"), systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Label {
                        Text(tr("Open on YouTube Music", "在 YouTube Music 打开"))
                    } icon: {
                        YouTubeMark(size: 12)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(tr("Open on YouTube Music", "在 YouTube Music 打开"))
            }
        }
    }
}

extension View {
    func catalogReleaseContextMenu(
        release: CatalogReleaseProjection,
        onOpen: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) -> some View {
        modifier(CatalogCollectionContextMenu(
            tracks: release.tracks,
            openTitle: tr("Open Album", "打开专辑"),
            playTitle: tr("Play Album", "播放专辑"),
            shuffleTitle: tr("Shuffle Album", "随机播放专辑"),
            addTitle: tr("Add Album to Queue", "将专辑加入队列"),
            link: YouTubeCatalogLink.releaseURL(stableID: release.stableID),
            onOpen: onOpen,
            onPlay: onPlay,
            onShuffle: onShuffle
        ))
    }

    func catalogArtistContextMenu(
        artist: CatalogArtistProjection,
        onOpen: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) -> some View {
        modifier(CatalogCollectionContextMenu(
            tracks: artist.tracks,
            openTitle: tr("Open Artist", "打开艺术家"),
            playTitle: tr("Play Artist", "播放艺术家"),
            shuffleTitle: tr("Shuffle Artist", "随机播放艺术家"),
            addTitle: tr("Add Artist to Queue", "将艺术家加入队列"),
            link: YouTubeCatalogLink.artistURL(stableID: artist.stableID),
            onOpen: onOpen,
            onPlay: onPlay,
            onShuffle: onShuffle
        ))
    }
}
