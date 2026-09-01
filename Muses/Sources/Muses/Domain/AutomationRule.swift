import Foundation
import SwiftData

/// 自动化触发器(Final Spec §12 Feature 12 — Context Automation)。映射到 PlaybackEvent。
enum AutomationTrigger: String, Codable, Sendable, CaseIterable {
    case trackStarted
    case trackCompleted
    case trackSkipped

    var label: String {
        switch self {
        case .trackStarted:   return tr("When a track starts", "曲目开始时")
        case .trackCompleted: return tr("When a track completes", "曲目播完时")
        case .trackSkipped:   return tr("When a track is skipped", "曲目被跳过时")
        }
    }
}

/// 自动化条件集合(Final Spec §12)。所有非 nil 字段必须同时满足(AND 语义)。
/// 对无上下文的事件(contextSummaryJSON 为 nil):app/时段时间条件视为不匹配,
/// 绝不伪造上下文。
struct AutomationConditions: Codable, Sendable, Equatable {
    /// 前台应用 bundle id 精确匹配(需 contextTrackActiveApp 开启才有数据)。
    var appBundleId: String?
    /// 时段匹配(morning/afternoon/evening/lateNight)。
    var timeBand: ListeningContext.TimeBand?
    /// 耳机连接匹配。
    var isHeadphones: Bool?
    /// 周末匹配。
    var isWeekend: Bool?

    init(appBundleId: String? = nil, timeBand: ListeningContext.TimeBand? = nil,
         isHeadphones: Bool? = nil, isWeekend: Bool? = nil) {
        self.appBundleId = appBundleId; self.timeBand = timeBand
        self.isHeadphones = isHeadphones; self.isWeekend = isWeekend
    }
}

/// 自动化动作(Final Spec §12)。
enum AutomationAction: String, Codable, Sendable, CaseIterable {
    case likeTrack        // 收藏当前曲目(已收藏则 no-op)
    case addToInbox       // 加入收件箱
    case playNext         // 插入为下一首
    case addToQueue       // 加入队列末尾

    var label: String {
        switch self {
        case .likeTrack:   return tr("Like track", "收藏曲目")
        case .addToInbox:  return tr("Add to Inbox", "加入收件箱")
        case .playNext:    return tr("Play next", "下一首播放")
        case .addToQueue:  return tr("Add to queue", "加入队列")
        }
    }
}

/// 自动化规则(Final Spec §6 / §12)。`conditionsJSON` 为编码的 `AutomationConditions?`(nil=无条件)。
@Model
final class AutomationRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var enabled: Bool
    var triggerRaw: String
    var conditionsJSON: String?
    var actionRaw: String
    /// 冷却(毫秒):两次触发间最小间隔,防循环/抖动。nil=无冷却。
    var cooldownMs: Int?
    var lastFiredAt: Date?

    init(id: UUID = UUID(), name: String, enabled: Bool = true,
         trigger: AutomationTrigger, conditions: AutomationConditions? = nil,
         action: AutomationAction, cooldownMs: Int? = nil, lastFiredAt: Date? = nil) {
        self.id = id; self.name = name; self.enabled = enabled
        self.triggerRaw = trigger.rawValue
        if let conditions {
            self.conditionsJSON = (try? JSONEncoder().encode(conditions))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            self.conditionsJSON = nil
        }
        self.actionRaw = action.rawValue
        self.cooldownMs = cooldownMs; self.lastFiredAt = lastFiredAt
    }

    var trigger: AutomationTrigger { AutomationTrigger(rawValue: triggerRaw) ?? .trackStarted }
    var action: AutomationAction { AutomationAction(rawValue: actionRaw) ?? .likeTrack }
    var conditions: AutomationConditions? {
        guard let conditionsJSON, let data = conditionsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutomationConditions.self, from: data)
    }
}
