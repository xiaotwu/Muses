import Foundation
import SwiftData

/// 一次「收听会话」:从首次播放到「显式停止 / 长时空闲 / 队列耗尽」之间的连续播放段。
///
/// 设计要点(对应 Final Spec §6 / §10.5):
/// - 与 `ListeningEvent` 是 1:N(`ListeningEvent.sessionId` 指回本表 `id`)。会话是「时段」,
///   事件是「单曲记录」;回顾 / 恢复两者互补。
/// - `queueSnapshotJSON` 是该会话启动(及曲目切换)时队列的自包含快照(供回顾/审计);
///   真正用于「崩溃恢复 / 启动恢复」的槽位是 `QueueState` 单行上的
///   `currentTrackId` / `lastPositionMs`(由 `SessionService` 在 checkpoint 时同步写入),
///   本行的 `currentTrackId` / `currentPositionMs` 是同一次 checkpoint 的会话侧副本。
/// - `statusRaw`:`active` = 进行中(可被启动恢复对话框捕获);`ended` = 已结束
///   (显式停止 / 队列耗尽 / 超过 2h 空闲自动结束 / 用户选择「重新开始」)。
/// - `contextSummaryJSON` 为 Phase 23 Contextual Listening 预留位,本阶段恒为 nil。
///
/// 索引同 `ListeningEvent` 暂不声明显式 `@Index`,保持与 autoschema 轻量迁移策略一致,
/// 留待会话量级达到后再补齐(Final Spec §15 允许的次要实现变更)。
@Model
final class ListeningSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var statusRaw: String            // SessionStatus.rawValue
    var queueSnapshotJSON: String?
    var currentTrackId: UUID?
    var currentPositionMs: Double?
    var contextSummaryJSON: String?

    init(id: UUID = UUID(), startedAt: Date = .init(), updatedAt: Date? = nil,
         endedAt: Date? = nil, status: SessionStatus = .active,
         queueSnapshotJSON: String? = nil, currentTrackId: UUID? = nil,
         currentPositionMs: Double? = nil, contextSummaryJSON: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.endedAt = endedAt
        self.statusRaw = status.rawValue
        self.queueSnapshotJSON = queueSnapshotJSON
        self.currentTrackId = currentTrackId
        self.currentPositionMs = currentPositionMs
        self.contextSummaryJSON = contextSummaryJSON
    }

    var status: SessionStatus { SessionStatus(rawValue: statusRaw) ?? .active }
}

/// 会话状态。`active` 可被下一次启动的恢复对话框捕获;`ended` 仅供回顾查询。
enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case ended
}