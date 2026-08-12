import Foundation
import SwiftData

/// 歌单条目:有序关联 `Playlist` ↔ `Track`。
///
/// `order` 字段维护条目在歌单内的排列顺序(从 0 开始)。
/// 删 Track 时 `track` 断开(nullify);删 Playlist 时级联删条目。
@Model
final class PlaylistItem {
    @Attribute(.unique) var id: UUID
    var order: Int
    var playlist: Playlist?
    var track: Track?

    init(id: UUID = UUID(), order: Int, playlist: Playlist? = nil, track: Track? = nil) {
        self.id = id
        self.order = order
        self.playlist = playlist
        self.track = track
    }
}