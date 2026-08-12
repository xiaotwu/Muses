import Foundation
import SwiftData

/// 一次 YouTube 歌单链接导入(独立管理实体)。
///
/// 镜像 YT 侧的只读条目(`items: [YouTubeImportItem]`),并维护本地附加曲目
/// (`localAdditions: [Track]`)——本地附加仅在本地显示,**绝不**同步回 YT。
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

    /// YT 侧只读条目(级联删除:删 import 时一并删 items)。
    @Relationship(deleteRule: .cascade, inverse: \YouTubeImportItem.import_)
    var items: [YouTubeImportItem]?

    /// 本地附加到该歌单的曲目(仅本地显示,不同步回 YT)。
    /// `nullify` 删除规则:删 import 时仅断开关联,不删 Track。
    @Relationship(deleteRule: .nullify, inverse: \Track.youTubeImportLocalAddition)
    var localAdditions: [Track]?

    init(id: UUID = UUID(), playlistId: String, url: String, title: String,
         channel: String, artworkUrl: String? = nil,
         importedAt: Date = .init(), lastSyncedAt: Date? = nil) {
        self.id = id; self.playlistId = playlistId; self.url = url
        self.title = title; self.channel = channel; self.artworkUrl = artworkUrl
        self.importedAt = importedAt; self.lastSyncedAt = lastSyncedAt
        self.items = []
        self.localAdditions = []
    }
}