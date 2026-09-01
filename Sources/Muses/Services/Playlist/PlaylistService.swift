import Foundation
import SwiftData
import Observation

/// Complete local-only information needed to undo a playlist deletion during
/// the current session. It deliberately stores identifiers rather than model
/// objects so restoration can use a fresh SwiftData context.
struct PlaylistDeletionSnapshot: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let order: Int
        let trackID: UUID?
    }

    let name: String
    let createdAt: Date
    let pinned: Bool
    let items: [Item]
}

/// Playlist CRUD + ordering service.
///
/// Mirrors the `YouTubeImportService` pattern: `@MainActor @Observable`, a fresh `ModelContext` per operation,
/// and `try? ctx.save()` after each mutation.
@Observable
@MainActor
final class PlaylistService {
    private let modelContainer: ModelContainer
    private let log = AppLog.for("PlaylistService")
    private(set) var loadState: LoadState<[Playlist]> = .idle

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Playlist CRUD

    /// Creates a playlist and returns the new `Playlist`.
    @discardableResult
    func create(name: String) -> Playlist {
        let ctx = ModelContext(modelContainer)
        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        ctx.insert(playlist)
        try? ctx.save()
        log.info("创建歌单 \(playlist.name)")
        notifyPlaylistsChanged()
        return playlist
    }

    /// Renames a playlist.
    func rename(_ playlist: Playlist, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlist.name = trimmed
        try? playlist.modelContext?.save()
        notifyPlaylistsChanged()
    }

    /// Deletes a playlist (cascades to its items).
    func delete(_ playlist: Playlist) {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id }
        )
        if let p = try? ctx.fetch(descriptor).first {
            ctx.delete(p)
            try? ctx.save()
            log.info("删除歌单 \(id)")
            notifyPlaylistsChanged()
        }
    }

    /// Deletes a local playlist and returns a one-session restore capsule.
    /// The playlist's tracks remain untouched; detached item rows are restored
    /// as such if their track was removed in the meantime.
    func deleteWithUndoSnapshot(_ playlist: Playlist) -> PlaylistDeletionSnapshot? {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        let descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        guard let stored = try? ctx.fetch(descriptor).first else { return nil }

        let snapshot = PlaylistDeletionSnapshot(
            name: stored.name,
            createdAt: stored.createdAt,
            pinned: stored.pinned,
            items: (stored.items ?? []).sorted { $0.order < $1.order }.map {
                .init(order: $0.order, trackID: $0.track?.id)
            }
        )
        ctx.delete(stored)
        do {
            try ctx.save()
            log.info("删除歌单 (id)，可在当前会话撤销")
            notifyPlaylistsChanged()
            return snapshot
        } catch {
            log.warning("删除歌单失败: (error.localizedDescription)")
            return nil
        }
    }

    /// Restores a deletion capsule once. Missing tracks remain represented by
    /// a detached playlist item, matching the model's existing nullify rule.
    @discardableResult
    func restore(_ snapshot: PlaylistDeletionSnapshot) -> Playlist? {
        let ctx = ModelContext(modelContainer)
        let restored = Playlist(name: snapshot.name, createdAt: snapshot.createdAt,
                                pinned: snapshot.pinned)
        ctx.insert(restored)
        var restoredItems: [PlaylistItem] = []
        for item in snapshot.items {
            let track: Track?
            if let id = item.trackID {
                track = try? ctx.fetch(FetchDescriptor<Track>(
                    predicate: #Predicate { $0.id == id }
                )).first
            } else {
                track = nil
            }
            let restoredItem = PlaylistItem(order: item.order, playlist: restored, track: track)
            ctx.insert(restoredItem)
            restoredItems.append(restoredItem)
        }
        restored.items = restoredItems
        do {
            try ctx.save()
            notifyPlaylistsChanged()
            return restored
        } catch {
            log.warning("恢复已删除歌单失败: (error.localizedDescription)")
            return nil
        }
    }

    private func notifyPlaylistsChanged() {
        NotificationCenter.default.post(name: .musesPlaylistsChanged, object: nil)
    }

    /// Fetches all playlists (newest first by creation time).
    func fetchAll() -> [Playlist] {
        let previous = loadState.value
        loadState = .loading(previous: previous)
        let ctx = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        do {
            let values = try ctx.fetch(descriptor)
            loadState = values.isEmpty ? .empty : .content(values)
            return values
        } catch {
            loadState = .failure(message: error.localizedDescription,
                                 staleValue: previous)
            return previous ?? []
        }
    }

    // MARK: - Item management

    /// Appends a track to a playlist (order = max + 1).
    func addTrack(_ playlist: Playlist, track: Track) {
        let ctx = ModelContext(modelContainer)
        let playlistId = playlist.id
        let trackId = track.id

        // Fetch persistent references for playlist + track in the new context
        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == playlistId }
        )).first else { return }
        guard let t = try? ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == trackId }
        )).first else { return }

        // Deduplicate: skip if the same track is already in the playlist
        let existingTrackIds = (p.items ?? []).compactMap { $0.track?.id }
        if existingTrackIds.contains(trackId) { return }

        let nextOrder = (p.items ?? []).map { $0.order }.max() ?? -1
        let item = PlaylistItem(order: nextOrder + 1, playlist: p, track: t)
        ctx.insert(item)
        if var items = p.items {
            items.append(item)
            p.items = items
        } else {
            p.items = [item]
        }
        try? ctx.save()
    }

    /// Removes an item from a playlist (deletes it and renumbers the remaining order).
    func removeItem(_ item: PlaylistItem) {
        let ctx = ModelContext(modelContainer)
        let itemId = item.id
        guard let i = try? ctx.fetch(FetchDescriptor<PlaylistItem>(
            predicate: #Predicate { $0.id == itemId }
        )).first else { return }
        let playlist = i.playlist
        ctx.delete(i)
        try? ctx.save()

        // Renumber the remaining order
        if let playlist, var items = playlist.items {
            items.sort { $0.order < $1.order }
            for (idx, item) in items.enumerated() {
                item.order = idx
            }
            playlist.items = items
            try? ctx.save()
        }
    }

    /// Drag reordering: moves the entry at `from` to `to` and renumbers order.
    func moveItem(in playlist: Playlist, from: Int, to: Int) {
        guard var items = playlist.items?.sorted(by: { $0.order < $1.order }),
              from < items.count, to <= items.count else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(to, items.count))
        for (idx, item) in items.enumerated() {
            item.order = idx
        }
        playlist.items = items
        try? playlist.modelContext?.save()
    }

    // MARK: - Pins

    /// Toggles a playlist's pinned state.
    func togglePin(_ playlist: Playlist) {
        let ctx = ModelContext(modelContainer)
        let id = playlist.id
        guard let p = try? ctx.fetch(FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.id == id }
        )).first else { return }
        p.pinned.toggle()
        try? ctx.save()
        notifyPlaylistsChanged()
    }

    /// Fetches pinned playlists (sorted by name).
    func pinnedPlaylists() -> [Playlist] {
        let ctx = ModelContext(modelContainer)
        let desc = FetchDescriptor<Playlist>(
            predicate: #Predicate { $0.pinned == true },
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? ctx.fetch(desc)) ?? []
    }

}
