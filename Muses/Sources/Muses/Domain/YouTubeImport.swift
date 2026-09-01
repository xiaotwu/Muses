import Foundation
import SwiftData

/// 一次 YouTube 歌单链接导入(独立管理实体)。
///
/// Local playlist state for an imported/connected YouTube playlist.
/// Remote changes are represented separately by Base and Remote Shadow
/// revisions; this row is never mutated by an unattended remote check.
@Model
final class YouTubeImport {
    @Attribute(.unique) var id: UUID
    /// YT 歌单 id(如 `PLxxxxxxx`),用于重新同步。
    var playlistId: String
    /// 原始导入 URL。
    var url: String
    /// 歌单标题(来自 yt-dlp flat-playlist 的 playlist 字段)。
    var title: String
    /// 歌单频道/上传者。
    var channel: String
    /// 歌单封面 URL(可缺省)。
    var artworkUrl: String?
    /// 首次导入时间。
    var importedAt: Date
    /// 上次重新同步时间。
    var lastSyncedAt: Date?
    /// Owning YouTube channel. Nil means legacy/public import until reconciled.
    var accountChannelID: String?
    /// Latest time Remote Shadow was checked without applying it locally.
    var remoteCheckedAt: Date?
    /// Accepted common Base revision identifier.
    var baseRevisionID: UUID?
    /// Latest Remote Shadow revision identifier.
    var remoteShadowRevisionID: UUID?
    /// Soft deletion timestamp. Recently Deleted retains the row for 30 days.
    var deletedAt: Date?
    /// Whether the active owner/API identified this playlist as writable.
    var remoteWritable: Bool?

    /// YT 侧只读条目(级联删除:删 import 时一并删 items)。
    @Relationship(deleteRule: .cascade, inverse: \YouTubeImportItem.import_)
    var items: [YouTubeImportItem]?

    init(id: UUID = UUID(), playlistId: String, url: String, title: String,
         channel: String, artworkUrl: String? = nil,
         importedAt: Date = .init(), lastSyncedAt: Date? = nil,
         accountChannelID: String? = nil) {
        self.id = id; self.playlistId = playlistId; self.url = url
        self.title = title; self.channel = channel; self.artworkUrl = artworkUrl
        self.importedAt = importedAt; self.lastSyncedAt = lastSyncedAt
        self.accountChannelID = accountChannelID
        self.remoteCheckedAt = nil
        self.baseRevisionID = nil
        self.remoteShadowRevisionID = nil
        self.deletedAt = nil
        self.remoteWritable = nil
        self.items = []
    }
}
