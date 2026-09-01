import Foundation
import SwiftData

/// Automation trigger (Final Spec §12 Feature 12 — Context Automation). Maps to PlaybackEvent.
enum AutomationTrigger: String, Codable, Sendable, CaseIterable {
    case trackStarted
    case trackCompleted
    case trackSkipped

    var label: String {
        switch self {
        case .trackStarted:   return tr("When a track starts", "曲目开始时")
        case .trackCompleted: return tr("When a track completes", "曲目播完时")
        case .trackSkipped:   return tr("When a track is skipped", "曲目被跳过时")
        }
    }
}

/// Automation condition set (Final Spec §12). All non-nil fields must match simultaneously (AND semantics).
/// For events without context (contextSummaryJSON nil), app/time-band conditions are treated as
/// non-matching — context is never fabricated.
struct AutomationConditions: Codable, Sendable, Equatable {
    /// Exact frontmost-app bundle id match (data exists only when contextTrackActiveApp is on).
    var appBundleId: String?
    /// Time-band match (morning/afternoon/evening/lateNight).
    var timeBand: ListeningContext.TimeBand?
    /// Headphone-connection match.
    var isHeadphones: Bool?
    /// Weekend match.
    var isWeekend: Bool?

    init(appBundleId: String? = nil, timeBand: ListeningContext.TimeBand? = nil,
         isHeadphones: Bool? = nil, isWeekend: Bool? = nil) {
        self.appBundleId = appBundleId; self.timeBand = timeBand
        self.isHeadphones = isHeadphones; self.isWeekend = isWeekend
    }
}

/// Automation action (Final Spec §12).
enum AutomationAction: String, Codable, Sendable, CaseIterable {
    case likeTrack        // Like the current track (no-op if already liked)
    case addToInbox       // Add to the inbox
    case playNext         // Insert as the next track
    case addToQueue       // Append to the end of the queue

    var label: String {
        switch self {
        case .likeTrack:   return tr("Like track", "收藏曲目")
        case .addToInbox:  return tr("Add to Inbox", "加入收件箱")
        case .playNext:    return tr("Play next", "下一首播放")
        case .addToQueue:  return tr("Add to queue", "加入队列")
        }
    }
}

/// Automation rule (Final Spec §6 / §12). `conditionsJSON` is the encoded `AutomationConditions?` (nil = unconditional).
@Model
final class AutomationRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var enabled: Bool
    var triggerRaw: String
    var conditionsJSON: String?
    var actionRaw: String
    /// Cooldown in milliseconds: minimum interval between firings, guarding against loops/flapping. nil = no cooldown.
    var cooldownMs: Int?
    var lastFiredAt: Date?

    init(id: UUID = UUID(), name: String, enabled: Bool = true,
         trigger: AutomationTrigger, conditions: AutomationConditions? = nil,
         action: AutomationAction, cooldownMs: Int? = nil, lastFiredAt: Date? = nil) {
        self.id = id; self.name = name; self.enabled = enabled
        self.triggerRaw = trigger.rawValue
        if let conditions {
            self.conditionsJSON = (try? JSONEncoder().encode(conditions))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            self.conditionsJSON = nil
        }
        self.actionRaw = action.rawValue
        self.cooldownMs = cooldownMs; self.lastFiredAt = lastFiredAt
    }

    var trigger: AutomationTrigger { AutomationTrigger(rawValue: triggerRaw) ?? .trackStarted }
    var action: AutomationAction { AutomationAction(rawValue: actionRaw) ?? .likeTrack }
    var conditions: AutomationConditions? {
        guard let conditionsJSON, let data = conditionsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutomationConditions.self, from: data)
    }
}
