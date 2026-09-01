import Foundation
import SwiftData

/// Inbox item (Final Spec §10.6 Feature 6 — Music Inbox).
///
/// A pending track suggestion, added manually by the user, triggered by automation,
/// or saved from a YouTube import.
/// State machine: `unheard → listening → (accepted | rejected | snoozed)`;
/// when a `snoozed` item expires (`snoozeUntil <= now`) it returns to `unheard`.
///
/// `trackId` plus denormalized snapshot fields (title/artist/album/duration/youTubeId/artwork)
/// let the inbox keep rendering even if the source `Track` is deleted; `accept` writes back
/// to `Track.liked` via `trackId`.
/// Like `ListeningEvent`, no explicit `@Index` is declared (autoschema lightweight-migration policy).
@Model
final class InboxItem {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var trackTitle: String
    var artist: String
    var albumTitle: String?
    var durationSeconds: Double
    var youTubeId: String
    var artworkUrl: String?
    var addedAt: Date
    var sourceRaw: String          // InboxSource.rawValue
    var stateRaw: String          // InboxState.rawValue
    var snoozeUntil: Date?
    var listenedMs: Double?
    var notes: String?

    init(id: UUID = UUID(), trackId: UUID, trackTitle: String, artist: String,
         albumTitle: String?, durationSeconds: Double, youTubeId: String,
         artworkUrl: String?, addedAt: Date = .init(),
         source: InboxSource = .manual, state: InboxState = .unheard,
         snoozeUntil: Date? = nil, listenedMs: Double? = nil, notes: String? = nil) {
        self.id = id
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.youTubeId = youTubeId
        self.artworkUrl = artworkUrl
        self.addedAt = addedAt
        self.sourceRaw = source.rawValue
        self.stateRaw = state.rawValue
        self.snoozeUntil = snoozeUntil
        self.listenedMs = listenedMs
        self.notes = notes
    }

    var state: InboxState { InboxState(rawValue: stateRaw) ?? .unheard }
    var source: InboxSource { InboxSource(rawValue: sourceRaw) ?? .manual }
}

/// Inbox state machine (Final Spec §10.6).
enum InboxState: String, Codable, Sendable, CaseIterable {
    case unheard      // Pending (initial / snooze expired)
    case listening    // Auditioning (hit by trackStarted)
    case accepted     // Accepted (liked + metadata kept)
    case rejected     // Rejected
    case snoozed      // Snoozed (returns to unheard when snoozeUntil expires)
}

/// How an inbox item got here.
enum InboxSource: String, Codable, Sendable {
    case manual          // Added manually by the user (PlayerBar / context menu)
    case automation      // Automation rule
    case youTubeImport   // YouTube import "save to inbox"
}
