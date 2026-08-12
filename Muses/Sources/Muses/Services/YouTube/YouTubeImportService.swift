import Foundation
import SwiftData
import Observation

/// YouTube 歌单导入错误。
enum YouTubeImportError: LocalizedError, Equatable {
    /// URL 无法解析为合法的 YouTube 歌单链接(缺少 `list=` 参数)。
    case invalidURL
    /// 抓取到的歌单为空。
    case emptyPlaylist
    /// 指定 id 的 `YouTubeImport` 未找到。
    case notFound
    /// 网络/yt-dlp 传输错误,携带描述信息。
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无法解析 YouTube 歌单 URL(缺少 list 参数)"
        case .emptyPlaylist: "播放列表为空"
        case .notFound: "YouTube 导入记录未找到"
        case .networkError(let m): "网络错误:\(m)"
        }
    }

    static func == (lhs: YouTubeImportError, rhs: YouTubeImportError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

/// YouTube 歌单导入服务。
///
/// 镜像 `MetadataEnricherService` 的模式:`@MainActor`,每次操作新建
/// `ModelContext(modelContainer)`,网络通过注入的 `URLSession`,封面通过
/// `ArtworkCache` 落地,日志走 `AppLog`。
///
/// 职责:
///  - `importPlaylist(url:)` —— 通过 yt-dlp `--flat-playlist --dump-json` 抓取
///    歌单条目,创建 `YouTubeImport` + `YouTubeImportItem` + 懒创建的 `.youtube`
///    `Track`,并下载歌单封面(首条视频缩略图)。
///  - `resync(importId:)` —— 重新抓取并合并条目(新增/移除/更新),保留
///    `localAdditions`,不删除已脱离的 `Track`。
///  - `deleteImport(importId:deleteTracks:)` —— 删除导入(级联 items),
///    可选是否一并删除懒创建的 `Track`。
///  - `addLocalAddition` / `removeLocalAddition` —— 维护本地附加曲目。
@Observable
@MainActor
final class YouTubeImportService {
    private let bridge: any YTDlpBridgeProtocol
    private let modelContainer: ModelContainer
    private let artworkCache: ArtworkCache
    private let session: URLSession
    private let log = AppLog.for("YouTubeImportService")

    init(bridge: any YTDlpBridgeProtocol,
         modelContainer: ModelContainer,
         artworkCache: ArtworkCache = .default,
         session: URLSession = .shared) {
        self.bridge = bridge
        self.modelContainer = modelContainer
        self.artworkCache = artworkCache
        self.session = session
    }

    // MARK: - Import

    /// 导入一个 YouTube 歌单 URL,返回新建 `YouTubeImport` 的 id。
    ///
    /// 流程:
    /// 1. `bridge.fetchPlaylist` 抓取 flat-playlist 条目。
    /// 2. 从 URL 解析 `list=` 参数作为 `playlistId`;失败则抛 `.invalidURL`。
    /// 3. 调 YouTube oEmbed API 获取歌单真实标题/频道/封面;失败回退首条 entry。
    /// 4. 新建 `YouTubeImport`,为每个条目创建 item + 懒 `.youtube` Track。
    /// 5. 设置歌单封面 URL(oEmbed 或首条视频 hqdefault),下载并缓存(失败不阻塞)。
    func importPlaylist(url: String) async throws -> UUID {
        // 1. 抓取条目。
        let entries: [YTDlpBridge.YTDlpPlaylistEntry]
        do {
            entries = try await bridge.fetchPlaylist(url: url, timeout: 60)
        } catch {
            log.error("fetchPlaylist 失败:\(error.localizedDescription)")
            throw YouTubeImportError.networkError(error.localizedDescription)
        }

        // 2. 非空校验。
        guard !entries.isEmpty else {
            throw YouTubeImportError.emptyPlaylist
        }

        // 3. 解析 playlistId。
        guard let playlistId = extractPlaylistId(from: url) else {
            throw YouTubeImportError.invalidURL
        }

        // 4. oEmbed 获取歌单元数据(失败回退)。
        let meta = await fetchOEmbedMetadata(for: url)
        let title = meta?.title ?? "YouTube Playlist"
        let channel = meta?.channel ?? entries.first?.uploader ?? "Unknown"
        let oembedArtwork = meta?.artworkURL

        // 5. 新建 ModelContext。
        let ctx = ModelContext(modelContainer)

        // 6. 创建 import。
        let imp = YouTubeImport(
            playlistId: playlistId,
            url: url,
            title: title,
            channel: channel
        )
        ctx.insert(imp)

        // 7. 逐条创建 item + 懒 Track。
        var items: [YouTubeImportItem] = []
        for (index, entry) in entries.enumerated() {
            let durationMs = Int((entry.duration ?? 0) * 1000)
            let artist = entry.uploader ?? channel

            let item = YouTubeImportItem(
                youTubeId: entry.id,
                title: entry.title,
                artist: artist,
                durationMs: durationMs,
                order: index
            )
            ctx.insert(item)

            let track = Track(
                source: .youtube,
                title: entry.title,
                artist: artist,
                durationMs: durationMs,
                youTubeId: entry.id,
                artworkUrl: thumbnailURL(forVideoId: entry.id)
            )
            ctx.insert(track)

            item.track = track
            items.append(item)
        }
        imp.items = items

        // 8. 首次同步时间。
        imp.lastSyncedAt = Date()

        // 9. 歌单封面:oEmbed 缩略图优先,回退首条视频 hqdefault;下载缓存(失败不阻塞)。
        let artworkURLString = oembedArtwork
            ?? (entries.first.map { thumbnailURL(forVideoId: $0.id) })
        if let artworkURLString {
            imp.artworkUrl = artworkURLString
            if let artworkURL = URL(string: artworkURLString) {
                if let imageData = await get(artworkURL) {
                    if let hash = try? artworkCache.store(imageData) {
                        _ = hash
                    }
                }
            }
        }

        // 10. 保存。
        try ctx.save()

        log.info("导入歌单 \(playlistId)(\(title)),共 \(items.count) 条")
        return imp.id
    }

    // MARK: - Resync

    /// 重新同步指定导入:重新抓取歌单并合并条目。
    ///
    /// - 新增条目:创建 item + 懒 Track,追加到 `items`。
    /// - 消失条目:从 `items` 移除并删除 item(nullify,不删 Track)。
    /// - 既有条目:更新 title/artist/durationMs。
    /// - `localAdditions` 完全不动。
    /// - Returns: 导入存在并完成同步返回 `true`,否则 `false`。
    @discardableResult
    func resync(importId: UUID) async throws -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else {
            return false
        }

        // 重新抓取。
        let entries: [YTDlpBridge.YTDlpPlaylistEntry]
        do {
            entries = try await bridge.fetchPlaylist(url: imp.url, timeout: 60)
        } catch {
            log.error("resync fetchPlaylist 失败:\(error.localizedDescription)")
            throw YouTubeImportError.networkError(error.localizedDescription)
        }

        // 现有 items 按 youTubeId 索引。
        let existing = (imp.items ?? []).reduce(into: [String: YouTubeImportItem]()) { dict, item in
            dict[item.youTubeId] = item
        }
        let existingIds = Set(existing.keys)

        // 新条目按 youTubeId 索引。
        let entryMap = Dictionary(uniqueKeysWithValues:
            entries.map { ($0.id, $0) })
        let newIds = Set(entryMap.keys)

        // 移除消失的条目(nullify Track,不删 Track)。
        for removedId in existingIds.subtracting(newIds) {
            if let item = existing[removedId] {
                if var items = imp.items {
                    items.removeAll { $0.youTubeId == removedId }
                    imp.items = items
                }
                ctx.delete(item)
            }
        }

        // 追加新增条目 + 更新既有条目。
        // 用现有最大 order + 1 作为新条目起点,保证追加顺序稳定。
        var nextOrder = (imp.items ?? []).map { $0.order }.max() ?? -1
        for entry in entries {
            if let item = existing[entry.id] {
                // 更新可变字段。
                let durationMs = Int((entry.duration ?? 0) * 1000)
                let artist = entry.uploader ?? imp.channel
                if item.title != entry.title { item.title = entry.title }
                if item.artist != artist { item.artist = artist }
                if item.durationMs != durationMs { item.durationMs = durationMs }
                // 同步关联 Track 的可变字段。
                if let track = item.track {
                    if track.title != entry.title { track.title = entry.title }
                    if track.artist != artist { track.artist = artist }
                    if track.durationMs != durationMs { track.durationMs = durationMs }
                }
            } else {
                // 新增。
                nextOrder += 1
                let durationMs = Int((entry.duration ?? 0) * 1000)
                let artist = entry.uploader ?? imp.channel

                let item = YouTubeImportItem(
                    youTubeId: entry.id,
                    title: entry.title,
                    artist: artist,
                    durationMs: durationMs,
                    order: nextOrder
                )
                ctx.insert(item)

                let track = Track(
                    source: .youtube,
                    title: entry.title,
                    artist: artist,
                    durationMs: durationMs,
                    youTubeId: entry.id,
                    artworkUrl: thumbnailURL(forVideoId: entry.id)
                )
                ctx.insert(track)

                item.track = track
                if var items = imp.items {
                    items.append(item)
                    imp.items = items
                } else {
                    imp.items = [item]
                }
            }
        }

        imp.lastSyncedAt = Date()

        // 刷新歌单元数据(oEmbed)。
        if let meta = await fetchOEmbedMetadata(for: imp.url) {
            imp.title = meta.title
            imp.channel = meta.channel
            if let art = meta.artworkURL { imp.artworkUrl = art }
        }

        try ctx.save()

        log.info("resync 完成 \(imp.playlistId),当前 \(imp.items?.count ?? 0) 条")
        return true
    }

    // MARK: - Delete

    /// 删除指定导入。级联删除 items;若 `deleteTracks` 为 `true` 则一并删除
    /// items 关联的 Track 以及 `localAdditions` 中的 Track。
    func deleteImport(importId: UUID, deleteTracks: Bool = false) {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else {
            return
        }

        if deleteTracks {
            // 收集所有关联 Track(items.track + localAdditions),统一删除。
            var tracksToDelete: [Track] = []
            for item in (imp.items ?? []) {
                if let t = item.track { tracksToDelete.append(t) }
            }
            for t in (imp.localAdditions ?? []) {
                tracksToDelete.append(t)
            }
            for t in tracksToDelete {
                ctx.delete(t)
            }
        }

        ctx.delete(imp) // 级联删 items
        try? ctx.save()
    }

    // MARK: - Local additions

    /// 将一个本地 `Track` 作为附加曲目挂到指定导入上(去重)。
    @discardableResult
    func addLocalAddition(importId: UUID, trackId: UUID) -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx),
              let track = fetchTrackById(trackId, context: ctx) else {
            return false
        }

        var current = imp.localAdditions ?? []
        // 去重:按 id。
        if current.contains(where: { $0.id == trackId }) {
            // 已存在,视为成功。
            return true
        }
        current.append(track)
        imp.localAdditions = current
        try? ctx.save()
        return true
    }

    /// 从指定导入的本地附加中移除某个 `Track`(Track 本身不删除)。
    @discardableResult
    func removeLocalAddition(importId: UUID, trackId: UUID) -> Bool {
        let ctx = ModelContext(modelContainer)
        guard let imp = fetchImportById(importId, context: ctx) else {
            return false
        }

        var current = imp.localAdditions ?? []
        let before = current.count
        current.removeAll { $0.id == trackId }
        guard current.count != before else {
            // 没有变化也视为成功(可能本就不存在)。
            return true
        }
        imp.localAdditions = current
        try? ctx.save()
        return true
    }

    // MARK: - Helpers

    /// 从 YouTube oEmbed API 获取歌单元数据(标题/频道/封面)。
    /// 无需 API key;失败(404/网络)返回 nil,调用方回退。
    ///
    /// - Parameter playlistURL: 歌单 URL(含 `list=` 参数)。
    /// - Returns: `(title, channel, artworkURL?)` 或 nil。
    private func fetchOEmbedMetadata(for playlistURL: String) async -> (title: String, channel: String, artworkURL: String?)? {
        guard let encoded = playlistURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
            return nil
        }
        guard let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let channel = json["author_name"] as? String else {
            log.warning("oEmbed 解析失败或未返回,回退占位元数据")
            return nil
        }
        let artwork = json["thumbnail_url"] as? String
        return (title, channel, artwork)
    }

    /// 从 YouTube URL 中解析 `list=` 参数,返回歌单 id。
    /// 支持 `youtube.com/playlist?list=`, `youtube.com/watch?v=...&list=...`,
    /// `youtu.be/<id>?list=...` 等模式。
    private func extractPlaylistId(from url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        // 1) 标准 query `list=` 参数。
        if let items = comps.queryItems {
            if let list = items.first(where: { $0.name == "list" })?.value,
               !list.isEmpty {
                return list
            }
        }
        // 2) 某些 youtu.be 链接把 list 放在 query;上面已覆盖。
        // 3) 无 list 参数则无法确定歌单 id。
        return nil
    }

    /// 构造 YouTube 视频缩略图 URL(hqdefault)。
    private func thumbnailURL(forVideoId videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    /// GET 一个 URL 并返回 body data;传输错误或非 2xx 均返回 nil(不抛错)。
    private func get(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                log.warning("GET \(url) 非 2xx")
                return nil
            }
            return data
        } catch {
            log.error("GET \(url) 传输错误:\(error)")
            return nil
        }
    }

    /// 按 id 查询 `YouTubeImport`(fresh context)。
    private func fetchImportById(_ id: UUID, context ctx: ModelContext) -> YouTubeImport? {
        let descriptor = FetchDescriptor<YouTubeImport>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }

    /// 按 id 查询 `Track`(fresh context)。
    private func fetchTrackById(_ id: UUID, context ctx: ModelContext) -> Track? {
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }
}