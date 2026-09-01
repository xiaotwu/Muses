import Foundation
import SwiftData

/// Track note (Final Spec §10.7 Feature 7 — Notes & Bookmarks). One per track, upserted by trackId.
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

/// Track timestamp bookmark: tapping jumps to `timestampMs` (seconds). Multiple per track, shown in ascending timestampMs order.
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
