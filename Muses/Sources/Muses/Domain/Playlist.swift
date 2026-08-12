import Foundation
import SwiftData

/// 用户手动创建的歌单。
///
/// 关系:`items` → `PlaylistItem`(cascade,删歌单时级联删条目)。
/// `PlaylistItem.track` 为 nullify(删 Track 时断开关系,不删歌单条目)。
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    var items: [PlaylistItem]?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}