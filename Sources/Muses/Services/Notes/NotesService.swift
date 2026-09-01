import Foundation
import Observation
import SwiftData

/// Notes & bookmarks service (Final Spec §10.7 Feature 7 — Notes & Bookmarks).
///
/// Owns read/write access to the `TrackNote` / `TrackBookmark` tables.
/// - Track notes are upserted per ownerId (one per owner); empty content deletes the row.
/// - Track bookmarks: CRUD, read ascending by `timestampMs`.
/// - `searchNotes(query:)`: case-insensitive substring match over TrackNote content,
///   returning denormalized `NoteSearchHit`s (with owner title) for `GlobalSearchService` to render.
///
/// Feature flag `PrefKey.ffNotes` (off by default): when off, write methods are no-ops while
/// reads still work (so already-stored data stays visible); consistent with the sibling
/// services' "off = no-op" convention. `isEnabled` reads the flag source live.
@Observable
@MainActor
final class NotesService {
    private let modelContainer: ModelContainer
    private let enabledProvider: () -> Bool
    private(set) var revision: Int = 0
    var isEnabled: Bool { enabledProvider() }
    var container: ModelContainer { modelContainer }

    init(modelContainer: ModelContainer,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffNotes)
    }) {
        self.modelContainer = modelContainer
        self.enabledProvider = enabledProvider
    }

    // MARK: - Track notes

    func note(forTrack trackId: UUID) -> TrackNote? {
        let ctx = modelContainer.mainContext
        return (try? ctx.fetch(FetchDescriptor<TrackNote>()))?
            .first(where: { $0.trackId == trackId })
    }

    /// Writes a track note (upsert). Empty content → deletes the row. No-op when the feature is off.
    func setTrackNote(trackId: UUID, content: String) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        let existing = (try? ctx.fetch(FetchDescriptor<TrackNote>()))?
            .first(where: { $0.trackId == trackId })
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing { ctx.delete(existing); try? ctx.save(); revision &+= 1 }
            return
        }
        if let existing {
            existing.content = content; existing.updatedAt = .init()
        } else {
            ctx.insert(TrackNote(trackId: trackId, content: content))
        }
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - Track bookmarks

    func bookmarks(forTrack trackId: UUID) -> [TrackBookmark] {
        let ctx = modelContainer.mainContext
        return ((try? ctx.fetch(FetchDescriptor<TrackBookmark>())) ?? [])
            .filter { $0.trackId == trackId }
            .sorted { $0.timestampMs < $1.timestampMs }
    }

    @discardableResult
    func addBookmark(trackId: UUID, timestampMs: Double, title: String?, note: String?) -> UUID? {
        guard isEnabled else { return nil }
        let ctx = modelContainer.mainContext
        let bm = TrackBookmark(trackId: trackId, timestampMs: timestampMs, title: title, note: note)
        ctx.insert(bm)
        try? ctx.save()
        revision &+= 1
        return bm.id
    }

    func removeBookmark(id: UUID) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        guard let bm = (try? ctx.fetch(FetchDescriptor<TrackBookmark>()))?
            .first(where: { $0.id == id }) else { return }
        ctx.delete(bm)
        try? ctx.save()
        revision &+= 1
    }

    func updateBookmark(id: UUID, title: String?, note: String?) {
        guard isEnabled else { return }
        let ctx = modelContainer.mainContext
        guard let bm = (try? ctx.fetch(FetchDescriptor<TrackBookmark>()))?
            .first(where: { $0.id == id }) else { return }
        bm.title = title; bm.note = note
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - Search

    /// Note search result (denormalized: carries the owner title for UI display).
    struct NoteSearchHit: Identifiable, Sendable {
        let id: UUID
        let kind: Kind
        let ownerId: UUID
        let ownerTitle: String
        let snippet: String
        enum Kind: Sendable { case trackNote }
    }

    /// Substring match over TrackNote content; an empty `query` returns nothing. Resolves track titles.
    func searchNotes(query: String) -> [NoteSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let needle = q.lowercased()
        let ctx = modelContainer.mainContext
        var hits: [NoteSearchHit] = []
        if let trackNotes = try? ctx.fetch(FetchDescriptor<TrackNote>()) {
            let tracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
            for n in trackNotes where n.content.lowercased().contains(needle) {
                let title = tracks.first(where: { $0.id == n.trackId })?.title ?? tr("Unknown track", "未知曲目")
                hits.append(.init(id: n.id, kind: .trackNote, ownerId: n.trackId,
                                  ownerTitle: title, snippet: snippet(of: n.content, needle: needle)))
            }
        }
        return hits
    }

    /// Takes a snippet of at most ~80 characters around the match (for search-result previews).
    private func snippet(of content: String, needle: String) -> String {
        let lower = content.lowercased()
        guard let range = lower.range(of: needle) else { return String(content.prefix(80)) }
        let idx = range.lowerBound
        let start = content.index(idx, offsetBy: -min(40, content.distance(from: content.startIndex, to: idx)), limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(idx, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end])
    }
}
