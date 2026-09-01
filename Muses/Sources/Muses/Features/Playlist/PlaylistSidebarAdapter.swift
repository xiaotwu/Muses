import Foundation

/// 侧边栏「歌单」合并项:本地 `Playlist` 与 YouTube `YouTubeImport` 的统一呈现适配器。
///
/// 这是**纯 UI/内容统一**,不做持久化迁移。两类实体保持各自 `@Model` 与既有详情路径,
/// 仅在侧边栏合并为一个排序集合,并为 YouTube 项标注来源。未来若统一为单一 `Playlist`
/// 模型,只需替换此适配器的数据源,UI 无需改动。
struct SidebarPlaylistItem: Identifiable, Hashable {
    enum Origin: Hashable { case local, youtube }

    /// 跨类型唯一 id(前缀区分,避免 UUID 碰撞)。
    let id: String
    let name: String
    /// 排序键:本地用 `createdAt`,YouTube 用 `importedAt`。
    let sortDate: Date
    let origin: Origin
    let pinned: Bool
    /// 仅在对应来源非 nil;避免在 Hashable 中比较 @Model 引用的不稳定性,
    /// 路由时由调用方按 `origin` 取用。
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
    /// 合并本地歌单与 YouTube 导入,排序为侧边栏单一集合。
    /// 规则:钉选本地歌单置顶,其余按 `sortDate` 倒序(新在前)。
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