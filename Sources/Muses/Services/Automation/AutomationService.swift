import Foundation
import SwiftData
import Observation

/// Automation service (Final Spec §12 Feature 12 — Context Automation).
///
/// Subscribes to `PlaybackEventBus` and matches events against enabled `AutomationRule`s:
/// - Triggers (triggerRaw) map to event types (TrackStarted/Completed/Skipped).
/// - Conditions (`AutomationConditions`) are evaluated against the event snapshot
///   plus the current context (AND semantics).
/// - On a match outside the cooldown, the action runs and `lastFiredAt` is written back.
///
/// **Loop prevention / debouncing:**
/// - Cooldown (`cooldownMs`): minimum interval between two firings of a rule.
/// - Dispatch re-entrancy guard (`isDispatching`): if an action synchronously raises a new
///   event during the same `eventBus.post`, the service ignores it while the guard is active,
///   preventing immediate feedback loops (PlaybackService.load is usually asynchronous;
///   this is a cheap extra safety net).
/// - Failed actions are only logged and still respect the cooldown; never retried indefinitely
///   (Final Spec §15).
///
/// Feature flag `PrefKey.ffAutomation` (off by default): when disabled, `handle` returns
/// immediately without reading rules or executing actions.
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

    // MARK: - Event handling

    private func handle(_ event: PlaybackEvent) {
        // Dispatch re-entrancy guard: keeps events synchronously raised by actions from re-triggering rules within the same dispatch.
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

    // MARK: - Rule queries/writes

    private func enabledRules(matching trigger: AutomationTrigger) -> [AutomationRule] {
        let ctx = ModelContext(modelContainer)
        let all = (try? ctx.fetch(FetchDescriptor<AutomationRule>())) ?? []
        return all.filter { $0.enabled && $0.trigger == trigger }
    }

    /// Writes back `lastFiredAt` (used for the cooldown) and bumps the revision.
    private func recordFire(_ rule: AutomationRule, at now: Date) {
        let ctx = ModelContext(modelContainer)
        guard let stored = (try? ctx.fetch(FetchDescriptor<AutomationRule>()))?
            .first(where: { $0.id == rule.id }) else { return }
        stored.lastFiredAt = now
        try? ctx.save()
        revision &+= 1
    }

    // MARK: - CRUD (for AutomationView/tests)

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

    // MARK: - Condition matching (pure functions, easy to test)

    /// Evaluates conditions: every non-nil field must hold simultaneously. `conditions == nil` means "no conditions" and is always true.
    static func matches(_ conditions: AutomationConditions?, snapshot: TrackSnapshot,
                        context: ListeningContext?) -> Bool {
        guard let conditions else { return true }
        if let app = conditions.appBundleId {
            // No context or no recorded frontmost app → the app condition does not match (never fabricated).
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

    /// Cooldown check: `cooldownMs == nil` means no cooldown; otherwise `now - lastFiredAt >= cooldown`.
    static func cooldownAllows(_ rule: AutomationRule, now: Date) -> Bool {
        guard let cd = rule.cooldownMs, let last = rule.lastFiredAt else { return true }
        return now.timeIntervalSince(last) >= Double(cd) / 1000.0
    }

    // MARK: - Event mapping

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

    // MARK: - Default action handler (production wiring)

    /// Production action handler: wires into LibraryService/InboxService/PlaybackService.
    /// `likeTrack` is "ensure liked" (a no-op if already liked; it never un-likes).
    /// All other actions delegate directly.
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
