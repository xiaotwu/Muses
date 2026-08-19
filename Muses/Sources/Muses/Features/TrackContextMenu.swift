import SwiftUI

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
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(InboxService.self) private var inbox
    @Environment(PlaylistService.self) private var playlistService
    @State private var showEditTrack = false
    @State private var showTrackNotes = false

    func body(content: Content) -> some View {
        if let snapshot {
            content
                .contextMenu { menu(snapshot) }
                .sheet(isPresented: $showEditTrack) {
                    if let t = track { EditTrackSheet(track: t) }
                }
                .sheet(isPresented: $showTrackNotes) {
                    if let t = track { TrackNotesSheet(track: t) }
                }
        } else {
            content
        }
    }

    @ViewBuilder private func menu(_ snapshot: TrackSnapshot) -> some View {
        Button(tr("Play", "播放")) { onPlay() }
        Button(tr("Play Next", "下一首播放")) { playback.queue.playNext(snapshot) }
        Button(tr("Add to Queue", "加入队列")) { playback.queue.addToQueue(snapshot) }
        Button(tr("Add to Inbox", "加入收件箱")) { inbox.add(snapshot) }
        if let t = track {
            Divider()
            let _ = library.likedRevision
            let liked = library.isLiked(id: t.id)
            Button(liked ? tr("Unlike", "取消收藏") : tr("Like", "收藏")) {
                library.toggleLike(t)
            }
            if !playlists.isEmpty {
                Menu(tr("Add to Playlist", "添加到歌单")) {
                    ForEach(playlists, id: \.id) { pl in
                        Button(pl.name) { playlistService.addTrack(pl, track: t) }
                    }
                }
            }
            Divider()
            Button(tr("Edit Info", "编辑信息")) { showEditTrack = true }
            Button(tr("Notes & Bookmarks…", "笔记与书签…")) { showTrackNotes = true }
        }
    }
}

extension View {
    /// 附加标准曲目右键菜单。`track` 非 nil 启用库内操作;`snapshot` nil(曲目已删除)则不附加菜单。
    func trackContextMenu(snapshot: TrackSnapshot?,
                          track: Track? = nil,
                          playlists: [Playlist] = [],
                          onPlay: @escaping () -> Void) -> some View {
        modifier(TrackContextMenu(snapshot: snapshot, track: track,
                                  playlists: playlists, onPlay: onPlay))
    }
}