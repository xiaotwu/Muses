import Foundation
import SwiftData

enum CatalogReleaseEvidenceKind: String, Codable, Sendable {
    case youtubeImportItem
    case catalogBrowse
}

enum CatalogReleaseMembershipError: Error {
    case invalidReleaseIdentity
}

/// One source-backed edge in the Track–Release many-to-many graph.
///
/// Multiple rows may point from one Track UUID to the same release when the
/// user imported repeated occurrences. Catalog projections deduplicate the
/// relation while review and rollback retain every source occurrence.
@Model
final class CatalogTrackReleaseMembership {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var evidenceKey: String
    var trackID: UUID
    var releaseStableID: String
    var releaseOrder: Int?
    var evidenceKindRaw: String
    var sourceImportID: UUID?
    var sourceItemID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        evidenceKey: String,
        trackID: UUID,
        releaseStableID: String,
        releaseOrder: Int?,
        evidenceKind: CatalogReleaseEvidenceKind,
        sourceImportID: UUID? = nil,
        sourceItemID: UUID? = nil,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.evidenceKey = evidenceKey
        self.trackID = trackID
        self.releaseStableID = releaseStableID
        self.releaseOrder = releaseOrder
        self.evidenceKindRaw = evidenceKind.rawValue
        self.sourceImportID = sourceImportID
        self.sourceItemID = sourceItemID
        self.createdAt = createdAt
    }

    var evidenceKind: CatalogReleaseEvidenceKind {
        CatalogReleaseEvidenceKind(rawValue: evidenceKindRaw) ?? .catalogBrowse
    }
}

struct CatalogReleaseMembershipValue: Sendable, Equatable {
    let evidenceKey: String
    let trackID: UUID
    let releaseStableID: String
    let releaseOrder: Int?
    let evidenceKind: CatalogReleaseEvidenceKind?
    let sourceImportID: UUID?
    let sourceItemID: UUID?
    let isLegacyCompatibility: Bool
}

/// The only write path for source-backed release relationships. The legacy
/// Track fields remain readable for old stores, but are not the relation truth.
@MainActor
enum CatalogReleaseMembershipStore {
    nonisolated static func evidenceKey(
        trackID: UUID,
        releaseStableID: String,
        evidenceKind: CatalogReleaseEvidenceKind,
        sourceImportID: UUID? = nil,
        sourceItemID: UUID? = nil
    ) -> String {
        [
            trackID.uuidString.lowercased(),
            releaseStableID,
            evidenceKind.rawValue,
            sourceImportID?.uuidString.lowercased() ?? "-",
            sourceItemID?.uuidString.lowercased() ?? "-",
        ].joined(separator: "|")
    }

    @discardableResult
    static func upsert(
        track: Track,
        releaseStableID: String,
        releaseOrder: Int?,
        evidenceKind: CatalogReleaseEvidenceKind,
        sourceImportID: UUID? = nil,
        sourceItemID: UUID? = nil,
        context: ModelContext
    ) throws -> CatalogTrackReleaseMembership {
        guard YouTubeCatalogIdentity.isResolvedRelease(releaseStableID) else {
            throw CatalogReleaseMembershipError.invalidReleaseIdentity
        }
        let key = evidenceKey(
            trackID: track.id,
            releaseStableID: releaseStableID,
            evidenceKind: evidenceKind,
            sourceImportID: sourceImportID,
            sourceItemID: sourceItemID)
        let descriptor = FetchDescriptor<CatalogTrackReleaseMembership>(
            predicate: #Predicate { $0.evidenceKey == key })
        let membership = try context.fetch(descriptor).first
            ?? CatalogTrackReleaseMembership(
                evidenceKey: key,
                trackID: track.id,
                releaseStableID: releaseStableID,
                releaseOrder: releaseOrder,
                evidenceKind: evidenceKind,
                sourceImportID: sourceImportID,
                sourceItemID: sourceItemID)
        if membership.modelContext == nil { context.insert(membership) }
        membership.releaseOrder = releaseOrder

        // Compatibility for call sites not yet migrated to relation-aware
        // snapshots. Never replace an established primary with another edge.
        if !YouTubeCatalogIdentity.isResolvedRelease(track.releaseCatalogID) {
            track.releaseCatalogID = releaseStableID
            track.releaseOrder = releaseOrder
        }
        return membership
    }

    static func persisted(in context: ModelContext) throws
        -> [CatalogReleaseMembershipValue] {
        try context.fetch(FetchDescriptor<CatalogTrackReleaseMembership>()).map {
            CatalogReleaseMembershipValue(
                evidenceKey: $0.evidenceKey,
                trackID: $0.trackID,
                releaseStableID: $0.releaseStableID,
                releaseOrder: $0.releaseOrder,
                evidenceKind: $0.evidenceKind,
                sourceImportID: $0.sourceImportID,
                sourceItemID: $0.sourceItemID,
                isLegacyCompatibility: false)
        }
    }

    /// Adds an in-memory compatibility edge for old stores. This method never
    /// persists it, so startup and cache rebuilds cannot become migrations.
    static func values(for tracks: [Track], in context: ModelContext) throws
        -> [CatalogReleaseMembershipValue] {
        var result = try persisted(in: context)
        let persistedPairs = Set(result.map {
            Pair(trackID: $0.trackID, releaseStableID: $0.releaseStableID)
        })
        for track in tracks {
            guard let releaseID = track.releaseCatalogID,
                  YouTubeCatalogIdentity.isResolvedRelease(releaseID),
                  !persistedPairs.contains(Pair(
                    trackID: track.id, releaseStableID: releaseID)) else { continue }
            result.append(CatalogReleaseMembershipValue(
                evidenceKey: "legacy|\(track.id.uuidString.lowercased())|\(releaseID)",
                trackID: track.id,
                releaseStableID: releaseID,
                releaseOrder: track.releaseOrder,
                evidenceKind: nil,
                sourceImportID: nil,
                sourceItemID: nil,
                isLegacyCompatibility: true))
        }
        return result
    }

    private struct Pair: Hashable {
        let trackID: UUID
        let releaseStableID: String
    }
}
