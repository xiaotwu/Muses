import Foundation
import SwiftData
import Observation

/// YouTube 搜索服务:封装 `YTDlpBridge.searchYouTube` + 创建 `.youtube` Track。
///
/// 用法:用户输入关键词 → `search(query:)` 返回结果列表 →
/// `importAsTrack(entry:)` 创建持久化 Track 并返回 snapshot。
@Observable
@MainActor
final class YouTubeSearchService {
    private let bridge: any YTDlpBridgeProtocol
    private let modelContainer: ModelContainer
    private let log = AppLog.for("YouTubeSearchService")

    init(bridge: any YTDlpBridgeProtocol, modelContainer: ModelContainer) {
        self.bridge = bridge
        self.modelContainer = modelContainer
    }

    /// 搜索 YouTube 视频。
    /// - Returns: 匹配条目列表(标题/频道/时长/videoId)。
    func fetchPlaylist(url: String) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        try await bridge.fetchPlaylist(url: url, timeout: 60)
    }

    func search(query: String, limit: Int = 10) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        do {
            return try await bridge.searchYouTube(query: query, limit: limit, timeout: 30)
        } catch {
            log.error("searchYouTube 失败:\(error.localizedDescription)")
            throw YouTubeImportError.networkError(error.localizedDescription)
        }
    }

    /// 将搜索结果导入为 `.youtube` Track(若已存在同 youTubeId 则返回既有)。
    /// - Returns: 新建或既有 Track 的 TrackSnapshot(供播放)。
    @discardableResult
    func importAsTrack(entry: YTDlpBridge.YTDlpPlaylistEntry) async throws -> TrackSnapshot {
        let ctx = ModelContext(modelContainer)
        let videoId = entry.id
        let existing = try ctx.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.youTubeId == videoId }
        ))
        let track: Track
        if let existing = existing.first {
            track = existing
        } else {
            let durationMs = Int((entry.duration ?? 0) * 1000)
            let artist = entry.uploader ?? "Unknown"
            let artistStableID = YouTubeCatalogIdentity.artist(
                channelID: entry.channelID, browseID: nil)
            track = Track(
                title: entry.title,
                artist: artist,
                durationMs: durationMs,
                youTubeId: entry.id,
                artworkUrl: YouTubeThumbnail.urlString(videoId: entry.id),
                mediaKind: entry.inferredMediaKind,
                artistCatalogID: artistStableID
            )
            ctx.insert(track)
            if let artistStableID {
                let key = artistStableID
                let descriptor = FetchDescriptor<CatalogArtist>(
                    predicate: #Predicate { $0.stableID == key })
                if (try? ctx.fetch(descriptor).first) == nil {
                    ctx.insert(CatalogArtist(stableID: artistStableID, name: artist,
                                             channelID: entry.channelID))
                }
            }
            try ctx.save()
            log.info("导入搜索结果 \(entry.id)(\(entry.title))")
        }
        return TrackSnapshot(from: track)
    }
}
