import Foundation
import SwiftData

/// YT 侧的只读条目,隶属某个 `YouTubeImport`。
///
/// 每条目懒创建一个 `.youtube` `Track`(`track` 关联),播放时才由
/// `YouTubeStreamEngine` 调 yt-dlp 解析实际流 URL。
@Model
final class YouTubeImportItem {
    @Attribute(.unique) var id: UUID
    /// 所属导入(级联:删 import 时删 item)。
    var import_: YouTubeImport?
    /// YouTube 视频 id。
    var youTubeId: String
    /// YouTube playlistItem resource id. This, not video id, identifies a
    /// duplicate occurrence for delete/reorder operations.
    var playlistItemID: String?
    /// 条目标题。
    var title: String
    /// 条目艺术家(来自 uploader 或 title 解析)。
    var artist: String
    /// 时长(毫秒),0 表示未知。
    var durationMs: Int
    /// 在歌单中的顺序(从 0 起)。
    var order: Int
    /// `available`, `private`, `deleted`, `regionBlocked`, or `unknown`.
    var availabilityRaw: String?

    /// 指向懒创建的 `.youtube` Track。`nullify` 删除规则:删 item 时不删 Track
    /// (用户可能已在队列/歌单中引用)。
    @Relationship(deleteRule: .nullify, inverse: \Track.youTubeImportItems)
    var track: Track?

    init(id: UUID = UUID(), youTubeId: String, title: String, artist: String,
         durationMs: Int = 0, order: Int = 0, playlistItemID: String? = nil,
         availability: YouTubePlaylistItemAvailability = .available) {
        self.id = id; self.youTubeId = youTubeId; self.title = title
        self.artist = artist; self.durationMs = durationMs; self.order = order
        self.playlistItemID = playlistItemID
        self.availabilityRaw = availability.rawValue
        self.track = nil
    }

    var availability: YouTubePlaylistItemAvailability {
        get { YouTubePlaylistItemAvailability(rawValue: availabilityRaw ?? "") ?? .unknown }
        set { availabilityRaw = newValue.rawValue }
    }
}
