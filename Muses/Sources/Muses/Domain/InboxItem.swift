import Foundation
import SwiftData

/// 收件箱条目(Final Spec §10.6 Feature 6 — Music Inbox)。
///
/// 一条「待处理」的曲目建议:用户手动加入 / 自动化触发 / YouTube 导入保存而来。
/// 状态机:`unheard → listening → (accepted | rejected | snoozed)`;
/// `snoozed` 到期(`snoozeUntil <= now`)→ 回到 `unheard`。
///
/// `trackId` + 反规范化快照字段(title/artist/album/duration/youTubeId/artwork/filePath)
/// 使收件箱即使源 `Track` 被删除也能展示;`accept` 时按 `trackId` 回写 `Track.liked`。
/// 索引同 `ListeningEvent` 暂不声明显式 `@Index`(与 autoschema 轻量迁移策略一致)。
@Model
final class InboxItem {
    @Attribute(.unique) var id: UUID
    var trackId: UUID
    var trackTitle: String
    var artist: String
    var albumTitle: String?
    var durationSeconds: Double
    var youTubeId: String?
    var artworkUrl: String?
    var filePath: String?
    var addedAt: Date
    var sourceRaw: String          // InboxSource.rawValue
    var stateRaw: String          // InboxState.rawValue
    var snoozeUntil: Date?
    var listenedMs: Double?
    var notes: String?

    init(id: UUID = UUID(), trackId: UUID, trackTitle: String, artist: String,
         albumTitle: String?, durationSeconds: Double, youTubeId: String?,
         artworkUrl: String?, filePath: String?, addedAt: Date = .init(),
         source: InboxSource = .manual, state: InboxState = .unheard,
         snoozeUntil: Date? = nil, listenedMs: Double? = nil, notes: String? = nil) {
        self.id = id
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.artist = artist
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.youTubeId = youTubeId
        self.artworkUrl = artworkUrl
        self.filePath = filePath
        self.addedAt = addedAt
        self.sourceRaw = source.rawValue
        self.stateRaw = state.rawValue
        self.snoozeUntil = snoozeUntil
        self.listenedMs = listenedMs
        self.notes = notes
    }

    var state: InboxState { InboxState(rawValue: stateRaw) ?? .unheard }
    var source: InboxSource { InboxSource(rawValue: sourceRaw) ?? .manual }
}

/// 收件箱状态机(Final Spec §10.6)。
enum InboxState: String, Codable, Sendable, CaseIterable {
    case unheard      // 待处理(初始 / 延后到期)
    case listening    // 正在试听(trackStarted 命中)
    case accepted     // 接受(like + 保留元数据)
    case rejected     // 拒绝
    case snoozed      // 延后(snoozeUntil 到期 → unheard)
}

/// 收件箱条目来源。
enum InboxSource: String, Codable, Sendable {
    case manual          // 用户手动加入(PlayerBar / 右键菜单)
    case automation      // 自动化规则(Phase 23)
    case youTubeImport   // YouTube 导入「保存到收件箱」
}