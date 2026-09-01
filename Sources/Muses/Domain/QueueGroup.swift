import Foundation

/// Queue group (Advanced Queue).
///
/// Design decision (Final Spec §10.4 / §10.5): `QueueGroup` is not a standalone SwiftData
/// `@Model` table; like `QueueItem`, it is a `Codable` value type serialized into the single
/// `QueueState.groupsJSON` row.
/// Rationale:
/// 1. Mirrors the existing `QueueItem` (itemsJSON) and keeps the queue subsystem's single-row
///    atomic-persistence convention.
/// 2. §10.5 requires queue + groups + locked state to survive a crash together; a single-row
///    upsert is atomic, whereas cross-table writes need multi-row consistency and are more fragile.
/// 3. Group counts are tiny (single digits), so SwiftData indexed queries are unnecessary.
/// The spec's literal "`QueueGroup` @Model" wording conflicts with this; this implementation
/// is authoritative (noted in the commit message).
///
/// `order` is the ascending sort index; `collapsed` controls the folded state (UI display only).
struct QueueGroup: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    var order: Int
    var collapsed: Bool

    init(id: UUID = UUID(), name: String, order: Int, collapsed: Bool = false) {
        self.id = id; self.name = name; self.order = order; self.collapsed = collapsed
    }
}