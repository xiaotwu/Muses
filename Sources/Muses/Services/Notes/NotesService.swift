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
/// Feature flag `PrefKey.ffNotes` (on by default): when off, writes are rejected while
/// reads still work (so already-stored data stays visible); consistent with the sibling
/// services' read-only convention. `isEnabled` reads the flag source live.
@Observable
@MainActor
final class NotesService {
    private let modelContainer: ModelContainer
    private let enabledProvider: () -> Bool
    private let saveContext: (ModelContext) throws -> Void
    private(set) var revision: Int = 0
    private(set) var lastError: String?
    var isEnabled: Bool { enabledProvider() }
    var container: ModelContainer { modelContainer }

    init(modelContainer: ModelContainer,
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffNotes)
    }, saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.modelContainer = modelContainer
        self.enabledProvider = enabledProvider
        self.saveContext = saveContext
    }

    // MARK: - Track notes

    func note(forTrack trackId: UUID) -> TrackNote? {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetch(FetchDescriptor<TrackNote>()))?
            .first(where: { $0.trackId == trackId })
    }

    /// Each write uses an isolated context so a failed save cannot leak into autosave.
    @discardableResult
    func setTrackNote(trackId: UUID, content: String) -> Bool {
        persist { ctx in
            let existing = try ctx.fetch(FetchDescriptor<TrackNote>(
                predicate: #Predicate { $0.trackId == trackId })).first
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let existing { ctx.delete(existing) }
            } else if let existing {
                existing.content = content
                existing.updatedAt = .init()
            } else {
                ctx.insert(TrackNote(trackId: trackId, content: content))
            }
        }
    }

    // MARK: - Track bookmarks

    func bookmarks(forTrack trackId: UUID) -> [TrackBookmark] {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetch(FetchDescriptor<TrackBookmark>(
            predicate: #Predicate { $0.trackId == trackId },
            sortBy: [SortDescriptor(\.timestampMs)]))) ?? []
    }

    /// Despite its legacy name, timestampMs stores seconds. Keep existing data compatible.
    @discardableResult
    func addBookmark(trackId: UUID, timestampMs: Double, title: String?, note: String?) -> UUID? {
        guard timestampMs.isFinite, timestampMs >= 0, timestampMs < Double(Int.max) else {
            lastError = tr("Enter a valid bookmark time.", "请输入有效的书签时间。", zhHant: "請輸入有效的書籤時間。")
            return nil
        }
        let bm = TrackBookmark(trackId: trackId, timestampMs: timestampMs, title: title, note: note)
        return persist { $0.insert(bm) } ? bm.id : nil
    }

    @discardableResult
    func removeBookmark(id: UUID) -> Bool {
        persist { ctx in
            if let bm = try ctx.fetch(FetchDescriptor<TrackBookmark>(predicate: #Predicate { $0.id == id })).first {
                ctx.delete(bm)
            }
        }
    }

    @discardableResult
    func updateBookmark(id: UUID, title: String?, note: String?) -> Bool {
        persist { ctx in
            if let bm = try ctx.fetch(FetchDescriptor<TrackBookmark>(predicate: #Predicate { $0.id == id })).first {
                bm.title = title
                bm.note = note
            }
        }
    }

    private func persist(_ change: (ModelContext) throws -> Void) -> Bool {
        lastError = nil
        guard isEnabled else {
            lastError = tr("Notes are read-only.", "笔记为只读。", zhHant: "筆記為唯讀。")
            return false
        }
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        do {
            try change(ctx)
            try saveContext(ctx)
            revision &+= 1
            return true
        } catch {
            ctx.rollback()
            lastError = tr("Changes could not be saved. Try again.", "无法保存更改，请重试。", zhHant: "無法儲存變更，請再試一次。")
            return false
        }
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
        let ctx = ModelContext(modelContainer)
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
        guard let range = content.range(of: needle, options: .caseInsensitive) else { return String(content.prefix(80)) }
        let idx = range.lowerBound
        let start = content.index(idx, offsetBy: -min(40, content.distance(from: content.startIndex, to: idx)), limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(idx, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end])
    }
}
