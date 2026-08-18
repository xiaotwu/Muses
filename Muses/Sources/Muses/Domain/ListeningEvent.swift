import Foundation
import SwiftData

/// 单次收听事件:一首曲目从「开始播放」到「被完成 / 跳过 / 停止 / 中断」的全过程记录。
///
/// 设计要点(对应 Final Spec §6 / §10.3):
/// - **去规范化** `trackTitle`/`artist`/`albumTitle`/`sourceRaw`:历史必须在 `Track` 被删除后
///   仍然可查询、可展示;因此不与 `Track` 建立必需关系。
/// - `listenedMs` 为实际收听毫秒(由 `PlaybackService` 在事件发出时从 `state.position` 折算)。
/// - `completionRatio` = `listenedMs / durationMs`(0..1);时长未知时为 nil。
/// - `outcomeRaw` 由事件类型映射:`.trackCompleted`→completed、`.trackSkipped`→skipped、
///   `.trackStopped`→stopped、位移丢失(`.trackStarted` 覆盖未终结事件)→interrupted。
/// - `contextSummaryJSON` / `sessionId` 为 Phase 23 / Phase 18 预留位,本阶段恒为 nil。
///
/// 索引(`@Index` on trackId/startedAt/sessionId)为 100k+ 事件查询的预留性能优化,
/// 属非用户可见的实现细节;为与 Phase 16 的「autoschema 轻量迁移」策略保持一致并避免
/// 引入 `@Index` 宏在不同 macOS 版本的可用性风险,Phase 17 暂不声明显式索引,
/// 留待事件量级达到后再以单独的性能加固任务补齐(Final Spec §15 允许的次要实现变更)。
@Model
final class ListeningEvent {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var trackTitle: String
    var artist: String
    var albumTitle: String?
    var sourceRaw: String          // TrackSource.rawValue
    var startedAt: Date
    var endedAt: Date?
    var listenedMs: Int
    var completionRatio: Double?
    var outcomeRaw: String         // ListeningOutcome.rawValue
    var contextSummaryJSON: String?
    var sessionId: UUID?

    init(id: UUID = UUID(), trackId: UUID, trackTitle: String, artist: String,
         albumTitle: String? = nil, source: TrackSource, startedAt: Date,
         endedAt: Date? = nil, listenedMs: Int = 0, completionRatio: Double? = nil,
         outcome: ListeningOutcome, contextSummaryJSON: String? = nil,
         sessionId: UUID? = nil) {
        self.id = id
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumTitle = albumTitle
        self.sourceRaw = source.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.listenedMs = listenedMs
        self.completionRatio = completionRatio
        self.outcomeRaw = outcome.rawValue
        self.contextSummaryJSON = contextSummaryJSON
        self.sessionId = sessionId
    }

    var source: TrackSource { TrackSource(rawValue: sourceRaw) ?? .local }
    var outcome: ListeningOutcome { ListeningOutcome(rawValue: outcomeRaw) ?? .interrupted }
}

/// 收听事件的结局分类。`interrupted` 表示上一首未正常终结就被新曲目覆盖
/// (位移事件丢失的兜底,正常路径不会产生)。
enum ListeningOutcome: String, Codable, Sendable, CaseIterable {
    case completed   // 自然播完(引擎完成回调)
    case skipped     // 用户主动跳过且未达完成阈值
    case stopped     // 收听充分但非自然结束(切歌/退出)
    case interrupted // 未终结就被覆盖(兜底)
}

/// 收听历史查询过滤器(Final Spec §10.3:支持 title/artist/album/date/source/outcome 等)。
/// 全部字段可选,留 nil 表示不限制。`limit` 控制返回行数(默认 200,避免一次性载入全量)。
struct HistoryQuery: Sendable {
    var titleContains: String?
    var artistContains: String?
    var albumContains: String?
    var source: TrackSource?
    var outcome: ListeningOutcome?
    var fromDate: Date?
    var toDate: Date?
    var limit: Int = 200

    init(titleContains: String? = nil, artistContains: String? = nil,
         albumContains: String? = nil, source: TrackSource? = nil,
         outcome: ListeningOutcome? = nil, fromDate: Date? = nil,
         toDate: Date? = nil, limit: Int = 200) {
        self.titleContains = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistContains = artistContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.albumContains = albumContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.outcome = outcome
        self.fromDate = fromDate
        self.toDate = toDate
        self.limit = max(1, limit)
    }
}

/// 收听回顾汇总值(不可变,供 `HistoryView` 展示)。`topTracks`/`topArtists` 已按计数倒序截断。
struct ListeningRecap: Sendable {
    struct TrackTally: Sendable, Identifiable { let id: UUID; let title: String; let artist: String; let plays: Int; let listenedMs: Int }
    struct ArtistTally: Sendable, Identifiable { let id: String; let name: String; let plays: Int; let listenedMs: Int }

    let rangeLabel: String
    let totalListenedMs: Int
    let eventCount: Int
    let completedCount: Int
    let skippedCount: Int
    let uniqueTracks: Int
    let uniqueArtists: Int
    let localMs: Int
    let youtubeMs: Int
    let topTracks: [TrackTally]
    let topArtists: [ArtistTally]
}