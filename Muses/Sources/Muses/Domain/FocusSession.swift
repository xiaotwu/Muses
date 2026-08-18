import Foundation
import SwiftData

/// 专注会话(Final Spec §10.9 Feature 9 — Focus Mode)。
///
/// 一次「专注」的生命周期记录:开始时间、计划时长(可无 = 不限时)、结束时间、
/// 关联播放列表/收听会话、状态。仅作回顾用,不驱动播放;`FocusService` 持有运行态。
@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var plannedDurationMs: Int?
    var endedAt: Date?
    var playlistId: UUID?
    var listeningSessionId: UUID?
    var statusRaw: String

    init(id: UUID = UUID(), startedAt: Date = Date(), plannedDurationMs: Int? = nil,
         endedAt: Date? = nil, playlistId: UUID? = nil, listeningSessionId: UUID? = nil,
         status: FocusStatus = .active) {
        self.id = id
        self.startedAt = startedAt
        self.plannedDurationMs = plannedDurationMs
        self.endedAt = endedAt
        self.playlistId = playlistId
        self.listeningSessionId = listeningSessionId
        self.statusRaw = status.rawValue
    }

    var status: FocusStatus {
        get { FocusStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
}

/// 专注会话状态。
enum FocusStatus: String, Codable, Sendable {
    case active       // 进行中
    case completed   // 正常结束(到时 / 手动停止)
    case cancelled   // 异常中止
}

/// 计时到期时的行为。
enum FocusExpiration: String, Codable, Sendable, CaseIterable {
    case keepPlaying   // 继续播放(仅记录结束)
    case pause         // 暂停播放
    case notifyOnly    // 仅通知,不改播放状态

    var label: String {
        switch self {
        case .keepPlaying: return tr("Keep Playing", "继续播放")
        case .pause:       return tr("Pause", "暂停")
        case .notifyOnly:  return tr("Notify Only", "仅通知")
        }
    }
}