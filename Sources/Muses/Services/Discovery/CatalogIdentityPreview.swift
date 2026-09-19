import Foundation
import SwiftData

/// Direct persisted membership evidence. Repeated occurrences remain separate.
struct CatalogIdentityEvidence: Codable, Sendable, Equatable {
    let importID: UUID
    let itemID: UUID
    let releaseID: String
    let order: Int

    func membershipKey(trackID: UUID) -> String {
        CatalogReleaseMembershipStore.evidenceKey(
            trackID: trackID,
            releaseStableID: releaseID,
            evidenceKind: .youtubeImportItem,
            sourceImportID: importID,
            sourceItemID: itemID)
    }
}

struct CatalogIdentityPreview: Sendable, Equatable {
    enum Resolution: Sendable, Equatable {
        case alreadyResolved
        case proposed([String])
        case ambiguous
        case unresolved
    }

    struct Row: Sendable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let currentReleaseID: String?
        let currentReleaseIDs: [String]
        let membershipEvidenceKeys: [String]
        let evidence: [CatalogIdentityEvidence]
        let resolution: Resolution
    }

    let rows: [Row]

    /// No cache rebuild, network request, model mutation, or implicit video-ID merge.
    @MainActor
    static func read(from container: ModelContainer) throws -> Self {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let items = try context.fetch(FetchDescriptor<YouTubeImportItem>())
        let membershipValues = try CatalogReleaseMembershipStore.values(
            for: tracks, in: context)
        let membershipsByTrack = Dictionary(grouping: membershipValues, by: \.trackID)
        var evidenceByTrack: [UUID: [CatalogIdentityEvidence]] = [:]
        for item in items {
            guard let track = item.track,
                  let owner = item.import_,
                  track.youTubeId == item.youTubeId,
                  item.youTubeId.count == 11,
                  YouTubeShareTarget(kind: .video, id: item.youTubeId)?.id == item.youTubeId,
                  YouTubePlaylistID.isMusicAlbum(owner.playlistId) else { continue }
            let releaseID = "playlist:\(owner.playlistId)"
            guard YouTubeCatalogIdentity.isResolvedRelease(releaseID) else { continue }
            evidenceByTrack[track.id, default: []].append(.init(
                importID: owner.id, itemID: item.id, releaseID: releaseID, order: item.order))
        }
        let rows = tracks.sorted { $0.id.uuidString < $1.id.uuidString }.map { track in
            let evidence = (evidenceByTrack[track.id] ?? []).sorted {
                if $0.releaseID != $1.releaseID { return $0.releaseID < $1.releaseID }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.itemID.uuidString < $1.itemID.uuidString
            }
            let currentValues = membershipsByTrack[track.id] ?? []
            let currentIDs = Set(currentValues.map(\.releaseStableID))
            let persistedEvidenceKeys = Set(currentValues
                .filter { !$0.isLegacyCompatibility }
                .map(\.evidenceKey))
            let missingEvidence = evidence.filter {
                !persistedEvidenceKeys.contains($0.membershipKey(trackID: track.id))
            }
            let missing = Set(missingEvidence.map(\.releaseID)).sorted()
            let resolution: Resolution
            if !missing.isEmpty {
                resolution = .proposed(missing)
            } else if !currentIDs.isEmpty {
                resolution = .alreadyResolved
            } else {
                resolution = .unresolved
            }
            return Row(id: track.id, title: track.title,
                       currentReleaseID: track.releaseCatalogID,
                       currentReleaseIDs: currentIDs.sorted(),
                       membershipEvidenceKeys: persistedEvidenceKeys.sorted(),
                       evidence: evidence, resolution: resolution)
        }
        return Self(rows: rows)
    }
}
