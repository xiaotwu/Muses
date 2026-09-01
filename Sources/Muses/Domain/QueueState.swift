import Foundation
import SwiftData

/// Single-row SwiftData model that persists queue state. Upserts use a fixed UUID
/// so `QueueService.restore()` always lands on the same row.
@Model
final class QueueState {
    @Attribute(.unique) var id: UUID
    var itemsJSON: String
    var currentIndex: Int
    var upNextJSON: String
    var historyJSON: String
    var repeatModeRaw: String
    var shuffle: Bool
    var savedAt: Date
    /// Crash recovery: id of the track playing when the app quit or crashed (used by session restore). nil = no record.
    var currentTrackId: UUID?
    /// Crash recovery: playback position at the last checkpoint, in milliseconds. nil = no record.
    /// (The field name says Ms, and the `trackSeeked(toMs:)` event is also in ms; on restore, `seek(to:)` takes seconds, so divide by 1000.)
    var lastPositionMs: Double?
    /// Advanced queue: JSON of the queue groups (`[QueueGroup]`). nil = no groups.
    var groupsJSON: String?

    /// Fixed UUID used by the singleton persisted row.
    static let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(id: UUID = QueueState.sharedID,
         itemsJSON: String,
         currentIndex: Int,
         upNextJSON: String,
         historyJSON: String,
         repeatModeRaw: String,
         shuffle: Bool,
         savedAt: Date = .init(),
         currentTrackId: UUID? = nil,
         lastPositionMs: Double? = nil,
         groupsJSON: String? = nil) {
        self.id = id
        self.itemsJSON = itemsJSON
        self.currentIndex = currentIndex
        self.upNextJSON = upNextJSON
        self.historyJSON = historyJSON
        self.repeatModeRaw = repeatModeRaw
        self.shuffle = shuffle
        self.savedAt = savedAt
        self.currentTrackId = currentTrackId
        self.lastPositionMs = lastPositionMs
        self.groupsJSON = groupsJSON
    }
}
