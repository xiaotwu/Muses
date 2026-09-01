import Foundation
import SwiftData

/// 曲目笔记(Final Spec §10.7 Feature 7 — Notes & Bookmarks)。每曲目一条(按 trackId upsert)。
@Model
final class TrackNote {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), trackId: UUID, content: String = "",
         createdAt: Date = .init(), updatedAt: Date? = nil) {
        self.id = id; self.trackId = trackId; self.content = content
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// 曲目时间戳书签:点击跳转到 `timestampMs`(秒)。每曲目可有多条,按 timestampMs 升序展示。
@Model
final class TrackBookmark {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var timestampMs: Double
    var title: String?
    var note: String?
    var createdAt: Date

    init(id: UUID = UUID(), trackId: UUID, timestampMs: Double,
         title: String? = nil, note: String? = nil, createdAt: Date = .init()) {
        self.id = id; self.trackId = trackId; self.timestampMs = timestampMs
        self.title = title; self.note = note; self.createdAt = createdAt
    }
}
