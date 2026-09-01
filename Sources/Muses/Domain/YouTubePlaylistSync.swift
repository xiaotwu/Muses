import Foundation
import SwiftData
import CryptoKit

enum YouTubePlaylistItemAvailability: String, Codable, Sendable, CaseIterable {
    case available
    case `private`
    case deleted
    case regionBlocked
    case unknown
}

struct YouTubePlaylistItemSnapshot: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var playlistItemID: String?
    var videoID: String
    /// Optional metadata is descriptive, not structural. Nil means unknown;
    /// it must not be collapsed into an empty string or zero during sync.
    var title: String?
    var artist: String?
    var durationMs: Int?
    var order: Int
    var availability: YouTubePlaylistItemAvailability

    var identity: YouTubePlaylistOccurrenceIdentity {
        .init(localItemID: id, remotePlaylistItemID: normalizedPlaylistItemID,
              contentVideoID: videoID)
    }

    var normalizedPlaylistItemID: String? {
        guard let value = playlistItemID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    var knownTitle: String? { title?.nonEmptyMetadata }
    var knownArtist: String? { artist?.nonEmptyMetadata }
    var knownDurationMs: Int? {
        guard let durationMs, durationMs > 0 else { return nil }
        return durationMs
    }

    /// Stable occurrence identity. Duplicate videos remain distinct.
    var occurrenceKey: String {
        if let playlistItemID = normalizedPlaylistItemID {
            return "remote:\(playlistItemID)"
        }
        return "local:\(id.uuidString.lowercased())"
    }

    /// Only playlist structure participates in Pull/Push conflict detection.
    /// Metadata freshness is merged separately and cannot create a move/edit.
    var structuralValue: YouTubePlaylistItemStructuralValue {
        .init(occurrenceKey: occurrenceKey, videoID: videoID, order: order,
              availability: availability)
    }

    func fillingUnknownMetadata(from fallbacks: YouTubePlaylistItemSnapshot? ...)
        -> YouTubePlaylistItemSnapshot {
        var result = self
        for fallback in fallbacks {
            guard let fallback else { continue }
            if result.knownTitle == nil { result.title = fallback.knownTitle }
            if result.knownArtist == nil { result.artist = fallback.knownArtist }
            if result.knownDurationMs == nil { result.durationMs = fallback.knownDurationMs }
        }
        return result
    }
}

struct YouTubePlaylistOccurrenceIdentity: Codable, Sendable, Hashable {
    let localItemID: UUID
    let remotePlaylistItemID: String?
    let contentVideoID: String
}

struct YouTubePlaylistItemStructuralValue: Sendable, Hashable {
    let occurrenceKey: String
    let videoID: String
    let order: Int
    let availability: YouTubePlaylistItemAvailability
}

private extension String {
    var nonEmptyMetadata: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct YouTubePlaylistSnapshot: Codable, Sendable, Equatable {
    var playlistID: String
    var accountChannelID: String?
    var title: String
    var capturedAt: Date
    var items: [YouTubePlaylistItemSnapshot]
    /// Present only for Data API Remote/Partial Shadow snapshots. Legacy
    /// revisions decode as nil and are therefore not trusted for destructive
    /// sync planning.
    var pagination: YouTubePlaylistPaginationMetadata? = nil

    var normalizedItems: [YouTubePlaylistItemSnapshot] {
        items.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.occurrenceKey < $1.occurrenceKey
        }
    }

    var fingerprint: String {
        let rows = normalizedItems.map {
            [$0.occurrenceKey, $0.videoID, String($0.order),
             $0.availability.rawValue].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isStructurallyEquivalent(to other: YouTubePlaylistSnapshot) -> Bool {
        normalizedItems.map(\.structuralValue) == other.normalizedItems.map(\.structuralValue)
    }

    var isCompleteRemote: Bool {
        pagination?.completeness.isComplete == true
    }
}

struct YouTubePlaylistPaginationMetadata: Codable, Sendable, Equatable {
    let completeness: PaginationCompleteness
    let pageCount: Int
    let nextPageToken: String?
    let itemCount: Int
}

enum YouTubePlaylistRevisionKind: String, Codable, Sendable, Equatable {
    case base
    case local
    case remoteShadow
    case remotePartial
    case beforePull
    case beforePush
    case beforeDelete
    case beforeRestore
    case restored
}

struct YouTubePlaylistRevisionSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let importID: UUID
    let kind: YouTubePlaylistRevisionKind
    let createdAt: Date
    let fingerprint: String
    let pinned: Bool
    let itemCount: Int
}

enum YouTubePlaylistRevisionChangeKind: String, Sendable, Equatable {
    case inserted
    case removed
    case moved
}

struct YouTubePlaylistRevisionChange: Sendable, Equatable, Identifiable {
    let id: String
    let kind: YouTubePlaylistRevisionChangeKind
    let item: YouTubePlaylistItemSnapshot
    let fromPosition: Int?
    let toPosition: Int?
}

struct YouTubePlaylistRevisionComparison: Sendable, Equatable {
    let olderRevisionID: UUID
    let newerRevisionID: UUID
    let changes: [YouTubePlaylistRevisionChange]

    var insertedCount: Int { changes.count { $0.kind == .inserted } }
    var removedCount: Int { changes.count { $0.kind == .removed } }
    var movedCount: Int { changes.count { $0.kind == .moved } }
}

/// Lightweight value used by the playlist overview. It is computed outside
/// SwiftUI `body` so cards can explain ownership and recovery state without
/// observing SwiftData relationships or rebuilding three-way diffs per frame.
struct YouTubePlaylistOverviewStatus: Sendable, Equatable {
    let lastRemoteCheckAt: Date?
    let lastPullAt: Date?
    let lastPushAt: Date?
    let pendingLocalChangeCount: Int
    let conflictCount: Int
    let hasIncompleteRemote: Bool
    let remoteWritable: Bool?
    let needsReview: Bool
    let errorMessage: String?
}

@Model
final class YouTubePlaylistRevision {
    @Attribute(.unique) var id: UUID
    var importID: UUID
    var accountChannelID: String?
    var kindRaw: String
    var createdAt: Date
    var snapshotData: Data
    var fingerprint: String
    var pinned: Bool

    init(id: UUID = UUID(), importID: UUID, accountChannelID: String?,
         kind: YouTubePlaylistRevisionKind, createdAt: Date = .init(),
         snapshotData: Data, fingerprint: String, pinned: Bool = false) {
        self.id = id
        self.importID = importID
        self.accountChannelID = accountChannelID
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.snapshotData = snapshotData
        self.fingerprint = fingerprint
        self.pinned = pinned
    }

    var kind: YouTubePlaylistRevisionKind {
        YouTubePlaylistRevisionKind(rawValue: kindRaw) ?? .local
    }

    func decodeSnapshot() throws -> YouTubePlaylistSnapshot {
        try JSONDecoder().decode(YouTubePlaylistSnapshot.self, from: snapshotData)
    }
}

enum YouTubeSyncOperationKind: String, Codable, Sendable {
    case insert
    case remove
    case move
}

enum YouTubeSyncOperationState: String, Codable, Sendable {
    case planned
    case started
    case remoteObserved
    case locallyCommitted
    case needsConfirmation
    case failed
}

enum YouTubeSyncBatchState: String, Codable, Sendable {
    case planned
    case started
    case remoteObserved
    case locallyCommitted
    case needsReview
    case discarded
}

@Model
final class YouTubeSyncBatch {
    @Attribute(.unique) var id: UUID
    var importID: UUID
    var accountChannelID: String?
    var playlistID: String
    var stateRaw: String
    var baseRevisionID: UUID
    var localRevisionID: UUID
    var remoteRevisionID: UUID
    var expectedRemoteFingerprint: String
    var desiredSnapshotData: Data
    var preRemoteSnapshotData: Data
    var createdAt: Date
    var startedAt: Date?
    var remoteObservedAt: Date?
    var completedAt: Date?
    var invalidatedReason: String?

    init(id: UUID = UUID(), importID: UUID, accountChannelID: String?,
         playlistID: String, baseRevisionID: UUID, localRevisionID: UUID,
         remoteRevisionID: UUID, expectedRemoteFingerprint: String,
         desiredSnapshotData: Data, preRemoteSnapshotData: Data,
         createdAt: Date = .init()) {
        self.id = id
        self.importID = importID
        self.accountChannelID = accountChannelID
        self.playlistID = playlistID
        self.stateRaw = YouTubeSyncBatchState.planned.rawValue
        self.baseRevisionID = baseRevisionID
        self.localRevisionID = localRevisionID
        self.remoteRevisionID = remoteRevisionID
        self.expectedRemoteFingerprint = expectedRemoteFingerprint
        self.desiredSnapshotData = desiredSnapshotData
        self.preRemoteSnapshotData = preRemoteSnapshotData
        self.createdAt = createdAt
        self.startedAt = nil
        self.remoteObservedAt = nil
        self.completedAt = nil
        self.invalidatedReason = nil
    }

    var state: YouTubeSyncBatchState {
        get { YouTubeSyncBatchState(rawValue: stateRaw) ?? .needsReview }
        set { stateRaw = newValue.rawValue }
    }

    func decodeDesiredSnapshot() throws -> YouTubePlaylistSnapshot {
        try JSONDecoder().decode(YouTubePlaylistSnapshot.self, from: desiredSnapshotData)
    }

    func decodePreRemoteSnapshot() throws -> YouTubePlaylistSnapshot {
        try JSONDecoder().decode(YouTubePlaylistSnapshot.self, from: preRemoteSnapshotData)
    }
}

@Model
final class YouTubeSyncOperation {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var idempotencyKey: String
    var importID: UUID
    var accountChannelID: String?
    var batchID: UUID
    var sequence: Int
    var kindRaw: String
    var stateRaw: String
    var playlistItemID: String?
    var videoID: String
    var fromPosition: Int?
    var toPosition: Int?
    var previousPlaylistItemID: String?
    var nextPlaylistItemID: String?
    var remoteResultID: String?
    var attempts: Int
    var lastError: String?
    var createdAt: Date
    var startedAt: Date?
    var remoteObservedAt: Date?
    var completedAt: Date?

    init(id: UUID = UUID(), importID: UUID, accountChannelID: String?,
         batchID: UUID, sequence: Int, kind: YouTubeSyncOperationKind,
         playlistItemID: String?, videoID: String, fromPosition: Int? = nil,
         toPosition: Int? = nil, previousPlaylistItemID: String? = nil,
         nextPlaylistItemID: String? = nil) {
        self.id = id
        let targetIdentity = playlistItemID?.isEmpty == false ? playlistItemID! : videoID
        self.idempotencyKey = [
            batchID.uuidString.lowercased(), importID.uuidString.lowercased(),
            kind.rawValue, targetIdentity, toPosition.map(String.init) ?? "-"
        ].joined(separator: ":")
        self.importID = importID
        self.accountChannelID = accountChannelID
        self.batchID = batchID
        self.sequence = sequence
        self.kindRaw = kind.rawValue
        self.stateRaw = YouTubeSyncOperationState.planned.rawValue
        self.playlistItemID = playlistItemID
        self.videoID = videoID
        self.fromPosition = fromPosition
        self.toPosition = toPosition
        self.previousPlaylistItemID = previousPlaylistItemID
        self.nextPlaylistItemID = nextPlaylistItemID
        self.remoteResultID = nil
        self.attempts = 0
        self.lastError = nil
        self.createdAt = .init()
        self.startedAt = nil
        self.remoteObservedAt = nil
        self.completedAt = nil
    }

    var kind: YouTubeSyncOperationKind {
        YouTubeSyncOperationKind(rawValue: kindRaw) ?? .move
    }

    var state: YouTubeSyncOperationState {
        get {
            switch stateRaw {
            case "pending": return .planned
            case "running": return .started
            case "completed": return .locallyCommitted
            default: return YouTubeSyncOperationState(rawValue: stateRaw) ?? .failed
            }
        }
        set { stateRaw = newValue.rawValue }
    }
}

enum YouTubePlaylistConflictKind: String, Codable, Sendable {
    case divergentEdit
    case removedLocallyChangedRemotely
    case removedRemotelyChangedLocally
    case divergentMove
}

struct YouTubePlaylistConflict: Sendable, Equatable, Identifiable {
    let id: String
    let kind: YouTubePlaylistConflictKind
    let base: YouTubePlaylistItemSnapshot?
    let local: YouTubePlaylistItemSnapshot?
    let remote: YouTubePlaylistItemSnapshot?
}

struct YouTubePlaylistMergePlan: Sendable, Equatable {
    let localOnlyChanges: [String]
    let remoteOnlyChanges: [String]
    let conflicts: [YouTubePlaylistConflict]

    var requiresResolution: Bool { !conflicts.isEmpty }
}

enum YouTubePlaylistThreeWayMerge {
    static func plan(base: YouTubePlaylistSnapshot,
                     local: YouTubePlaylistSnapshot,
                     remote: YouTubePlaylistSnapshot) -> YouTubePlaylistMergePlan {
        let baseMap = Dictionary(uniqueKeysWithValues: base.items.map { ($0.occurrenceKey, $0) })
        let localMap = Dictionary(uniqueKeysWithValues: local.items.map { ($0.occurrenceKey, $0) })
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.occurrenceKey, $0) })
        let keys = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys).sorted()
        var localOnly: [String] = []
        var remoteOnly: [String] = []
        var conflicts: [YouTubePlaylistConflict] = []

        for key in keys {
            let baseItem = baseMap[key]
            let localItem = localMap[key]
            let remoteItem = remoteMap[key]
            let localChanged = !structurallyEqual(localItem, baseItem)
            let remoteChanged = !structurallyEqual(remoteItem, baseItem)
            if localChanged && remoteChanged && !structurallyEqual(localItem, remoteItem) {
                let kind: YouTubePlaylistConflictKind
                if localItem == nil { kind = .removedLocallyChangedRemotely }
                else if remoteItem == nil { kind = .removedRemotelyChangedLocally }
                else if localItem?.order != remoteItem?.order { kind = .divergentMove }
                else { kind = .divergentEdit }
                conflicts.append(.init(id: key, kind: kind, base: baseItem,
                                       local: localItem, remote: remoteItem))
            } else if localChanged {
                localOnly.append(key)
            } else if remoteChanged {
                remoteOnly.append(key)
            }
        }
        return .init(localOnlyChanges: localOnly, remoteOnlyChanges: remoteOnly,
                     conflicts: conflicts)
    }

    static func structurallyEqual(_ lhs: YouTubePlaylistItemSnapshot?,
                                  _ rhs: YouTubePlaylistItemSnapshot?) -> Bool {
        lhs?.structuralValue == rhs?.structuralValue
    }
}

struct YouTubePushOperation: Sendable, Equatable {
    let kind: YouTubeSyncOperationKind
    let playlistItemID: String?
    let videoID: String
    let fromPosition: Int?
    let toPosition: Int?
    let previousPlaylistItemID: String?
    let nextPlaylistItemID: String?
}

enum YouTubePushPlanner {
    /// Produces a deterministic mutation sequence while simulating every step.
    /// Existing occurrences are addressed only by playlistItem id.
    static func operations(remote: YouTubePlaylistSnapshot,
                           desired: YouTubePlaylistSnapshot) throws -> [YouTubePushOperation] {
        guard remote.isCompleteRemote else {
            throw YouTubePushPlanningError.incompleteRemote
        }
        var current = remote.normalizedItems
        let desiredItems = desired.normalizedItems
        let desiredKeys = Set(desiredItems.map(\.occurrenceKey))
        var operations: [YouTubePushOperation] = []

        for index in current.indices.reversed() where !desiredKeys.contains(current[index].occurrenceKey) {
            let item = current[index]
            operations.append(.init(kind: .remove, playlistItemID: item.playlistItemID,
                                    videoID: item.videoID, fromPosition: index, toPosition: nil,
                                    previousPlaylistItemID: current[safe: index - 1]?.playlistItemID,
                                    nextPlaylistItemID: current[safe: index + 1]?.playlistItemID))
            current.remove(at: index)
        }

        for target in desiredItems.indices {
            let wanted = desiredItems[target]
            if target < current.count, current[target].occurrenceKey == wanted.occurrenceKey { continue }
            if let source = current.firstIndex(where: { $0.occurrenceKey == wanted.occurrenceKey }) {
                let item = current.remove(at: source)
                current.insert(item, at: min(target, current.count))
                operations.append(.init(kind: .move, playlistItemID: item.playlistItemID,
                                        videoID: item.videoID, fromPosition: source,
                                        toPosition: target,
                                        previousPlaylistItemID: current[safe: target - 1]?.playlistItemID,
                                        nextPlaylistItemID: current[safe: target + 1]?.playlistItemID))
            } else {
                let previous = current[safe: target - 1]?.playlistItemID
                let next = current[safe: target]?.playlistItemID
                current.insert(wanted, at: min(target, current.count))
                operations.append(.init(kind: .insert, playlistItemID: nil,
                                        videoID: wanted.videoID, fromPosition: nil,
                                        toPosition: target,
                                        previousPlaylistItemID: previous,
                                        nextPlaylistItemID: next))
            }
        }
        return operations
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum YouTubePushPlanningError: LocalizedError, Sendable, Equatable {
    case incompleteRemote

    var errorDescription: String? {
        tr("Push planning requires a complete Remote Shadow",
           "生成推送计划需要完整的远端快照")
    }
}

enum YouTubePlaylistIdentityReconciler {
    struct Claim: Sendable, Equatable {
        let localItemID: UUID
        let remotePlaylistItemID: String
    }

    struct Result: Sendable, Equatable {
        let local: [YouTubePlaylistItemSnapshot]
        let remote: [YouTubePlaylistItemSnapshot]
        let claims: [Claim]
    }

    /// Reconciles three distinct identities without collapsing duplicate videos:
    /// local UUID, remote playlistItem id, and content video id. Existing remote
    /// ids win; legacy rows are matched by position plus identified neighbours.
    static func reconcile(
        local: [YouTubePlaylistItemSnapshot],
        remote: [YouTubePlaylistItemSnapshot]
    ) -> Result {
        var localItems = local.sorted { $0.order < $1.order }
        var remoteItems = remote.sorted { $0.order < $1.order }
        var usedRemoteIndexes: Set<Int> = []
        var claims: [Claim] = []

        var localByRemoteID: [String: UUID] = [:]
        for item in localItems {
            guard let remoteID = item.normalizedPlaylistItemID,
                  localByRemoteID[remoteID] == nil else { continue }
            localByRemoteID[remoteID] = item.id
        }
        for index in remoteItems.indices {
            guard let remoteID = remoteItems[index].normalizedPlaylistItemID,
                  let localID = localByRemoteID[remoteID],
                  let localIndex = localItems.firstIndex(where: { $0.id == localID }) else {
                continue
            }
            remoteItems[index].id = localID
            localItems[localIndex].playlistItemID = remoteID
            usedRemoteIndexes.insert(index)
        }

        for localIndex in localItems.indices where localItems[localIndex].normalizedPlaylistItemID == nil {
            let candidates = remoteItems.indices.filter {
                !usedRemoteIndexes.contains($0)
                    && remoteItems[$0].videoID == localItems[localIndex].videoID
                    && remoteItems[$0].normalizedPlaylistItemID != nil
            }
            guard let remoteIndex = candidates.max(by: {
                matchScore(localIndex: localIndex, remoteIndex: $0,
                           local: localItems, remote: remoteItems)
                    < matchScore(localIndex: localIndex, remoteIndex: $1,
                                 local: localItems, remote: remoteItems)
            }), let remoteID = remoteItems[remoteIndex].normalizedPlaylistItemID else {
                continue
            }
            localItems[localIndex].playlistItemID = remoteID
            remoteItems[remoteIndex].id = localItems[localIndex].id
            usedRemoteIndexes.insert(remoteIndex)
            claims.append(.init(localItemID: localItems[localIndex].id,
                                remotePlaylistItemID: remoteID))
        }

        return .init(local: localItems, remote: remoteItems, claims: claims)
    }

    /// Compatibility projection used by existing call sites and tests.
    static func adoptingRemoteItemIDs(
        local: [YouTubePlaylistItemSnapshot],
        remote: [YouTubePlaylistItemSnapshot]
    ) -> [YouTubePlaylistItemSnapshot] {
        reconcile(local: local, remote: remote).local
    }

    private static func matchScore(
        localIndex: Int, remoteIndex: Int,
        local: [YouTubePlaylistItemSnapshot], remote: [YouTubePlaylistItemSnapshot]
    ) -> Int {
        var score = -abs(local[localIndex].order - remote[remoteIndex].order) * 10
        if local[localIndex].order == remote[remoteIndex].order { score += 1_000 }
        score += neighbourScore(localIndex: localIndex, remoteIndex: remoteIndex,
                                offset: -1, local: local, remote: remote)
        score += neighbourScore(localIndex: localIndex, remoteIndex: remoteIndex,
                                offset: 1, local: local, remote: remote)
        return score
    }

    private static func neighbourScore(
        localIndex: Int, remoteIndex: Int, offset: Int,
        local: [YouTubePlaylistItemSnapshot], remote: [YouTubePlaylistItemSnapshot]
    ) -> Int {
        let localNeighbour = localIndex + offset
        let remoteNeighbour = remoteIndex + offset
        guard local.indices.contains(localNeighbour), remote.indices.contains(remoteNeighbour) else {
            return 0
        }
        if let localRemoteID = local[localNeighbour].normalizedPlaylistItemID,
           localRemoteID == remote[remoteNeighbour].normalizedPlaylistItemID {
            return 500
        }
        return local[localNeighbour].videoID == remote[remoteNeighbour].videoID ? 50 : 0
    }
}
