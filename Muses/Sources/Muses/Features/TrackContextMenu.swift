import SwiftUI
import AppKit

/// 复用:标准曲目右键菜单。统一歌曲行的菜单动作集,消除各列表「无右键 / 右键不全」问题(issue #2)。
///
/// - `track` 非 nil(本地库 @Model):启用收藏切换 / 添加到歌单 / 编辑信息 / 笔记与书签。
/// - `track` nil(仅快照:历史 / 搜索 / 首页 / 派生 / YouTube):仅播放类操作,
///   不对无 @Model 的曲目伪造收藏/编辑/歌单入口。
struct TrackContextMenu: ViewModifier {
    let snapshot: TrackSnapshot?
    var track: Track? = nil
    var playlists: [Playlist] = []
    let onPlay: () -> Void
    var onRemoveFromContainer: (() -> Void)? = nil
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @State private var showEditTrack = false
    @State private var showTrackNotes = false
    @State private var showCreatePlaylist = false

    func body(content: Content) -> some View {
        if let snapshot {
            content
                .contextMenu { menu(snapshot) }
                .sheet(isPresented: $showEditTrack) {
                    if let t = resolvedTrack(for: snapshot) { EditTrackSheet(track: t) }
                }
                .sheet(isPresented: $showTrackNotes) {
                    if let t = resolvedTrack(for: snapshot) { TrackNotesSheet(track: t) }
                }
                .sheet(isPresented: $showCreatePlaylist) {
                    NewPlaylistSheet(isPresented: $showCreatePlaylist) { name in
                        guard let t = resolvedTrack(for: snapshot) else { return }
                        let playlist = playlistService.create(name: name)
                        playlistService.addTrack(playlist, track: t)
                    }
                }
        } else {
            content
        }
    }

    private func menu(_ snapshot: TrackSnapshot) -> some View {
        TrackContextMenuItems(
            snapshot: snapshot,
            track: track,
            playlists: playlists,
            onPlay: onPlay,
            onRemoveFromContainer: onRemoveFromContainer,
            onEditTrack: { showEditTrack = true },
            onTrackNotes: { showTrackNotes = true },
            onCreatePlaylist: { showCreatePlaylist = true }
        )
    }

    private func resolvedTrack(for snapshot: TrackSnapshot) -> Track? {
        track ?? library.track(by: snapshot.id)
    }
}

/// Context menu for a YouTube discovery result that has not necessarily been
/// persisted as a `Track` yet. Queue and Inbox actions resolve the existing
/// library row (or create the lazy YouTube row) through the shared search
/// service before handing the snapshot to the existing services.
private struct YouTubeEntryContextMenu: ViewModifier {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void

    @Environment(YouTubeSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(InboxService.self) private var inbox

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(tr("Play", "播放"), systemImage: "play.fill", action: onPlay)
            Button(tr("Play Next", "下一首播放"), systemImage: "text.insert") {
                resolve { playback.queue.playNext($0) }
            }
            Button(tr("Add to Queue", "加入队列"), systemImage: "text.badge.plus") {
                resolve { playback.queue.addToQueue($0) }
            }
            Button(tr("Add to Inbox", "加入收件箱"), systemImage: "tray.and.arrow.down") {
                resolve { inbox.add($0) }
            }
            if let url = YouTubeContextMenuLink.watchURL(videoID: entry.id) {
                Button(tr("Copy Link", "复制链接"), systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label {
                        Text(tr("Open on YouTube", "在 YouTube 打开"))
                    } icon: {
                        YouTubeMark(size: 12)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))
            }
        }
    }

    private func resolve(_ action: @escaping @MainActor (TrackSnapshot) -> Void) {
        Task { @MainActor in
            guard let snapshot = try? await search.importAsTrack(entry: entry) else { return }
            action(snapshot)
        }
    }
}

enum YouTubeContextMenuLink {
    static func watchURL(videoID: String) -> URL? {
        let trimmed = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: trimmed)]
        return components?.url
    }
}

/// Shared menu content for cards and native Table selections. Presentation state
/// (sheets and dialogs) stays with the owning surface so a transient menu never owns it.
struct TrackContextMenuItems: View {
    let snapshot: TrackSnapshot
    var track: Track? = nil
    var playlists: [Playlist] = []
    let onPlay: () -> Void
    var onRemoveFromContainer: (() -> Void)? = nil
    var removeTitle: String = tr("Remove from Playlist", "从歌单移除")
    var showsPlayNext = true
    var showsAddToQueue = true
    var showsInbox = true
    var onEditTrack: (() -> Void)? = nil
    var onTrackNotes: (() -> Void)? = nil
    var onCreatePlaylist: (() -> Void)? = nil

    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(InboxService.self) private var inbox
    @Environment(PlaylistService.self) private var playlistService

    @ViewBuilder
    var body: some View {
        Button(tr("Play", "播放"), systemImage: "play.fill", action: onPlay)
        if showsPlayNext {
            Button(tr("Play Next", "下一首播放"), systemImage: "text.insert") {
                playback.queue.playNext(snapshot)
            }
        }
        if showsAddToQueue {
            Button(tr("Add to Queue", "加入队列"), systemImage: "text.badge.plus") {
                playback.queue.addToQueue(snapshot)
            }
        }
        if showsInbox {
            Button(tr("Add to Inbox", "加入收件箱"), systemImage: "tray.and.arrow.down") {
                inbox.add(snapshot)
            }
        }
        if !snapshot.youTubeId.isEmpty,
           let url = URL(string: "https://youtu.be/\(snapshot.youTubeId)") {
            Button(tr("Copy Link", "复制链接"), systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label {
                    Text(tr("Open on YouTube", "在 YouTube 打开"))
                } icon: {
                    YouTubeMark(size: 12)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(tr("Open on YouTube", "在 YouTube 打开"))
        }

        if let resolvedTrack {
            Divider()
            let _ = library.likedRevision
            let liked = library.isLiked(id: resolvedTrack.id)
            Button(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏")) {
                library.toggleLike(resolvedTrack)
            }
            if onCreatePlaylist != nil || !playlists.isEmpty {
                Menu(tr("Add to Playlist", "添加到歌单")) {
                    if let onCreatePlaylist {
                        Button(tr("New Playlist…", "新建歌单…"), action: onCreatePlaylist)
                    }
                    if !playlists.isEmpty {
                        if onCreatePlaylist != nil { Divider() }
                        ForEach(playlists, id: \.id) { playlist in
                            Button(playlist.name) {
                                playlistService.addTrack(playlist, track: resolvedTrack)
                            }
                        }
                    }
                }
            }
            if onEditTrack != nil || onTrackNotes != nil {
                Divider()
            }
            if let onEditTrack {
                Button(tr("Edit Info", "编辑信息"), action: onEditTrack)
            }
            if let onTrackNotes {
                Button(tr("Notes & Bookmarks…", "笔记与书签…"), action: onTrackNotes)
            }
        }

        if let onRemoveFromContainer {
            Divider()
            Button(
                removeTitle,
                role: .destructive,
                action: onRemoveFromContainer
            )
        }
    }

    private var resolvedTrack: Track? {
        track ?? library.track(by: snapshot.id)
    }
}

extension View {
    /// 附加标准曲目右键菜单。`track` 非 nil 启用库内操作;`snapshot` nil(曲目已删除)则不附加菜单。
    func trackContextMenu(snapshot: TrackSnapshot?,
                          track: Track? = nil,
                          playlists: [Playlist] = [],
                          onPlay: @escaping () -> Void,
                          onRemoveFromContainer: (() -> Void)? = nil) -> some View {
        modifier(TrackContextMenu(snapshot: snapshot, track: track,
                                  playlists: playlists, onPlay: onPlay,
                                  onRemoveFromContainer: onRemoveFromContainer))
    }

    /// Adds the standard playback/queue/inbox/link menu to a remote YouTube
    /// result while preserving the surface's existing collection-aware play action.
    func youTubeEntryContextMenu(
        entry: YTDlpBridge.YTDlpPlaylistEntry,
        onPlay: @escaping () -> Void
    ) -> some View {
        modifier(YouTubeEntryContextMenu(entry: entry, onPlay: onPlay))
    }

    @ViewBuilder
    func youTubeEntryContextMenu(
        card: YouTubeDiscoveryCard,
        onPlay: @escaping () -> Void
    ) -> some View {
        if let videoID = card.playableVideoID {
            youTubeEntryContextMenu(
                entry: YTDlpBridge.YTDlpPlaylistEntry(
                    id: videoID,
                    title: card.title,
                    uploader: card.uploader,
                    duration: card.duration
                ),
                onPlay: onPlay
            )
        } else {
            self
        }
    }
}
