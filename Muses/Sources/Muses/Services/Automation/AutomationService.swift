import Foundation
import SwiftData
import Observation

/// 自动化服务(Final Spec §12 Feature 12 — Context Automation)。
///
/// 订阅 `PlaybackEventBus`,把事件匹配到启用的 `AutomationRule`:
/// - 触发器(triggerRaw)映射到事件类型(TrackStarted/Completed/Skipped)。
/// - 条件(`AutomationConditions`)对事件快照 + 当前上下文求值(AND 语义)。
/// - 命中且冷却未到 → 执行动作;写回 `lastFiredAt`。
///
/// **防循环 / 防抖动:**
/// - 冷却(`cooldownMs`):两次触发间最小间隔。
/// - 派发重入守卫(`isDispatching`):同一 `eventBus.post` 期间,动作若同步引发新事件,
///   本服务在守卫期内忽略,避免即时回环(PlaybackService.load 通常异步,此处为廉价保险)。
/// - 动作执行失败只记日志、遵守冷却,绝不无限重试(Final Spec §15)。
///
/// 功能开关 `PrefKey.ffAutomation`(默认关):关闭时 handle 直接返回,不读规则不执行动作。
@Observable
@MainActor
final class AutomationService {
    private let modelContainer: ModelContainer
    private let eventBus: PlaybackEventBus
    private let contextProvider: () -> ListeningContext?
    private let enabledProvider: () -> Bool
    private let actionHandler: (AutomationAction, TrackSnapshot) -> Void
    private var subscription: UUID?
    private var isDispatching = false
    private(set) var revision: Int = 0
    var isEnabled: Bool { enabledProvider() }
    var container: ModelContainer { modelContainer }

    init(modelContainer: ModelContainer, eventBus: PlaybackEventBus,
         contextProvider: @escaping () -> ListeningContext? = { nil },
         enabledProvider: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PrefKey.ffAutomation)
    },
         actionHandler: @escaping (AutomationAction, TrackSnapshot) -> Void = { _, _ in }) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.contextProvider = contextProvider
        self.enabledProvider = enabledProvider
        self.actionHandler = actionHandler
        subscribe()
    }

    private func subscribe() {
        subscription = eventBus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: PlaybackEvent) {
        // 派发重入守卫:防止动作同步引发的事件在本派发期内再次触发规则。
        guard !isDispatching else { return }
        guard isEnabled else { return }
        guard let trigger = triggerFor(event), let snap = snapshotFor(event) else { return }

        let context = contextProvider()
        let rules = enabledRules(matching: trigger)
        guard !rules.isEmpty else { return }

        isDispatching = true
        defer { isDispatching = false }
        let now = Date()
        for rule in rules {
            guard Self.matches(rule.conditions, snapshot: snap, context: context) else { continue }
            guard Self.cooldownAllows(rule, now: now) else { continue }
            actionHandler(rule.action, snap)
            recordFire(rule, at: now)
        }
    }

    // MARK: - 规则查询/写入

    private func enabledRules(matching trigger: AutomationTrigger) -> [AutomationRule] {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<AutomationRule>())) ?? []
        return all.filter { $0.enabled && $0.trigger == trigger }
    }

    /// 写回 `lastFiredAt`(冷却用)并自增 revision。
    private func recordFire(_ rule: AutomationRule, at now: Date) {
        let ctx = ModelContext(modelContainer)
        guard let stored = (try? ctx.fetch(FetchDescriptor<AutomationRule>()))?
            .first(where: { $0.id == rule.id }) else { return }
        stored.lastFiredAt = now
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - CRUD(供 AutomationView/测试)

    @discardableResult
    func addRule(name: String, trigger: AutomationTrigger,
                 conditions: AutomationConditions? = nil,
                 action: AutomationAction, cooldownMs: Int? = nil) -> UUID {
        let ctx = ModelContext(modelContainer)
        let rule = AutomationRule(name: name, trigger: trigger,
                                  conditions: conditions, action: action,
                                  cooldownMs: cooldownMs)
        ctx.insert(rule)
        try? ctx.save()
        revision &+= 1
        return rule.id
    }

    func removeRule(id: UUID) {
        let ctx = ModelContext(modelContainer)
        guard let rule = (try? ctx.fetch(FetchDescriptor<AutomationRule>()))?
            .first(where: { $0.id == id }) else { return }
        ctx.delete(rule)
        try? ctx.save()
        revision &+= 1
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        let ctx = ModelContext(modelContainer)
        guard let rule = (try? ctx.fetch(FetchDescriptor<AutomationRule>()))?
            .first(where: { $0.id == id }) else { return }
        rule.enabled = enabled
        try? ctx.save()
        revision &+= 1
    }

    func allRules() -> [AutomationRule] {
        let ctx = ModelContext(modelContainer)
        return (try? ctx.fetch(FetchDescriptor<AutomationRule>())) ?? []
    }

    // MARK: - 条件匹配(纯函数,便于测试)

    /// 条件求值:所有非 nil 字段须同时满足。`conditions == nil` 视为无条件 → 恒真。
    static func matches(_ conditions: AutomationConditions?, snapshot: TrackSnapshot,
                        context: ListeningContext?) -> Bool {
        guard let conditions else { return true }
        if let app = conditions.appBundleId {
            // 无上下文或未记录前台应用 → 应用条件不匹配(绝不伪造)。
            guard context?.frontmostAppBundleId == app else { return false }
        }
        if let band = conditions.timeBand {
            guard context?.timeBand == band else { return false }
        }
        if let hp = conditions.isHeadphones {
            guard context?.isHeadphones == hp else { return false }
        }
        if let wk = conditions.isWeekend {
            guard context?.isWeekend == wk else { return false }
        }
        return true
    }

    /// 冷却检查:`cooldownMs == nil` 无冷却;否则 `now - lastFiredAt >= cooldown`。
    static func cooldownAllows(_ rule: AutomationRule, now: Date) -> Bool {
        guard let cd = rule.cooldownMs, let last = rule.lastFiredAt else { return true }
        return now.timeIntervalSince(last) >= Double(cd) / 1000.0
    }

    // MARK: - 事件映射

    private func triggerFor(_ event: PlaybackEvent) -> AutomationTrigger? {
        switch event {
        case .trackStarted:   return .trackStarted
        case .trackCompleted: return .trackCompleted
        case .trackSkipped:   return .trackSkipped
        default: return nil
        }
    }

    private func snapshotFor(_ event: PlaybackEvent) -> TrackSnapshot? {
        switch event {
        case .trackStarted(let s): return s
        case .trackCompleted(let s, _): return s
        case .trackSkipped(let s, _): return s
        case .trackStopped(let s, _): return s
        case .trackPaused(let s): return s
        case .trackResumed(let s): return s
        default: return nil
        }
    }

    // MARK: - 默认动作处理器(生产接线)

    /// 生产用动作处理器:接入 LibraryService/InboxService/PlaybackService。
    /// `likeTrack` 为「确保收藏」(已收藏则 no-op,不取消)。其余动作直接委派。
    static func makeDefaultActionHandler(library: LibraryService,
                                         inbox: InboxService,
                                         playback: PlaybackService)
        -> (AutomationAction, TrackSnapshot) -> Void {
        return { action, snap in
            switch action {
            case .likeTrack:
                if let t = library.track(by: snap.id), !t.liked {
                    library.toggleLike(t)
                }
            case .addToInbox:
                inbox.add(snap, source: .automation)
            case .playNext:
                playback.queue.playNext(snap)
            case .addToQueue:
                playback.queue.addToQueue(snap)
            }
        }
    }
}
