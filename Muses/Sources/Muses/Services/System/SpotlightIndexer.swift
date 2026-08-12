import Foundation
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers
import AppKit

/// Spotlight 索引器: 将 Track/Album 索引到 CoreSpotlight, 支持 deep link `muses://play?trackId=<id>`。
@MainActor
final class SpotlightIndexer {
    let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 索引所有 Track 和 Album 到 Spotlight。
    func indexAll() {
        let ctx = ModelContext(modelContainer)
        let tracks = (try? ctx.fetch(FetchDescriptor<Track>())) ?? []
        let albums = (try? ctx.fetch(FetchDescriptor<Album>())) ?? []
        index(tracks: tracks, albums: albums)
    }

    /// 索引指定的 Track 和 Album 列表。
    func index(tracks: [Track], albums: [Album]) {
        var items: [CSSearchableItem] = []

        for track in tracks {
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = track.title
            attrs.contentDescription = track.artist + (track.albumTitle.map { " · \($0)" } ?? "")
            attrs.artist = track.artist
            attrs.album = track.albumTitle
            attrs.genre = track.genre
            attrs.duration = track.durationSeconds as NSNumber?

            // 封面缩略图
            if let hash = track.localArtworkHash, let data = ArtworkCache.default.data(forHash: hash) {
                attrs.thumbnailData = data
            }

            // deep link: muses://play?trackId=<id>
            attrs.relatedUniqueIdentifier = track.id.uuidString
            let domain = "com.muses.track"
            let item = CSSearchableItem(uniqueIdentifier: track.id.uuidString,
                                        domainIdentifier: domain,
                                        attributeSet: attrs)
            item.domainIdentifier = domain
            items.append(item)
        }

        for album in albums {
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = album.title
            attrs.contentDescription = album.albumArtist
            attrs.artist = album.albumArtist

            if let hash = album.artworkHash, let data = ArtworkCache.default.data(forHash: hash) {
                attrs.thumbnailData = data
            }

            attrs.relatedUniqueIdentifier = album.id.uuidString
            let domain = "com.muses.album"
            let item = CSSearchableItem(uniqueIdentifier: album.id.uuidString,
                                        domainIdentifier: domain,
                                        attributeSet: attrs)
            items.append(item)
        }

        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                AppLog.for("SpotlightIndexer").error("index failed: \(error)")
            }
        }
    }

    /// 从 Spotlight 去索引。
    func deindex(ids: [UUID]) {
        let idStrings = ids.map(\.uuidString)
        guard !idStrings.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: idStrings) { error in
            if let error {
                AppLog.for("SpotlightIndexer").error("deindex failed: \(error)")
            }
        }
    }

    /// 清空所有 Muses 索引。
    func deindexAll() {
        CSSearchableIndex.default().deleteAllSearchableItems { error in
            if let error {
                AppLog.for("SpotlightIndexer").error("deindexAll failed: \(error)")
            }
        }
    }

    /// 处理 deep link URL: `muses://play?trackId=<id>` → 返回 trackId。
    static func trackId(from url: URL) -> UUID? {
        guard url.scheme == "muses", url.host == "play" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return comps?
            .queryItems?
            .first(where: { $0.name == "trackId" })?
            .value
            .flatMap(UUID.init(uuidString:))
    }
}