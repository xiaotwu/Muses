import Foundation

/// Adapter presenting local `Playlist`s and YouTube `YouTubeImport`s as one merged sidebar "Playlists" section.
///
/// This is a pure UI/content unification with no persistence migration. Both entities keep their own `@Model` and detail paths;
/// they are only merged into a single sorted collection for the sidebar, with YouTube items labeled by origin. If a single `Playlist`
/// model unifies them later, only this adapter's data source needs to change — the UI stays untouched.
struct SidebarPlaylistItem: Identifiable, Hashable {
    enum Origin: Hashable { case local, youtube }

    /// Cross-type unique id (prefixed to avoid UUID collisions).
    let id: String
    let name: String
    /// Sort keys: local playlists use `createdAt`, YouTube imports use `importedAt`.
    let sortDate: Date
    let origin: Origin
    let pinned: Bool
    /// Non-nil only for the corresponding origin; avoids comparing unstable @Model references in Hashable,
    /// callers resolve the reference by `origin` when routing.
    let playlistId: UUID?
    let youTubeImportId: UUID?

    init(playlist: Playlist) {
        self.id = "pl-\(playlist.id.uuidString)"
        self.name = playlist.name
        self.sortDate = playlist.createdAt
        self.origin = .local
        self.pinned = playlist.pinned
        self.playlistId = playlist.id
        self.youTubeImportId = nil
    }

    init(youTubeImport imp: YouTubeImport) {
        self.id = "yt-\(imp.id.uuidString)"
        self.name = imp.title
        self.sortDate = imp.importedAt
        self.origin = .youtube
        self.pinned = false
        self.playlistId = nil
        self.youTubeImportId = imp.id
    }

    var isYouTube: Bool { origin == .youtube }
}

enum SidebarPlaylistOrder {
    static func apply(_ items: [SidebarPlaylistItem]) -> [SidebarPlaylistItem] {
        let saved = (UserDefaults.standard.array(forKey: PrefKey.sidebarPlaylistOrder) as? [String]) ?? []
        guard !saved.isEmpty else { return items }
        var map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var out: [SidebarPlaylistItem] = []
        for id in saved {
            if let item = map.removeValue(forKey: id) { out.append(item) }
        }
        out.append(contentsOf: items.filter { map[$0.id] != nil })
        return out
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: PrefKey.sidebarPlaylistOrder)
    }
}

enum PlaylistSidebarAdapter {
    /// Merges local playlists and YouTube imports into one sorted sidebar collection.
    /// Rules: pinned local playlists first, then everything else by `sortDate` descending (newest first).
    static func merged(local: [Playlist], youTube: [YouTubeImport]) -> [SidebarPlaylistItem] {
        let localItems = local.map(SidebarPlaylistItem.init(playlist:))
        let ytItems = youTube.map(SidebarPlaylistItem.init(youTubeImport:))
        let combined = localItems + ytItems
        return combined.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.sortDate > b.sortDate
        }
    }
}