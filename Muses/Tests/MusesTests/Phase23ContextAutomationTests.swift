import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 23 — Contextual Listening + Automation 验收(Final Spec §10.2 Feature 2 / §12 Feature 12)。
@MainActor
@Suite("Phase 23 Context & Automation")
struct Phase23ContextAutomationTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ title: String, id: UUID = UUID(), youtube: Bool = false,
                      duration: Double = 200) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: "A", albumTitle: nil,
                      durationSeconds: duration, filePath: youtube ? nil : "/tmp/x.wav",
                      youTubeId: youtube ? "yt123" : nil, artworkHash: nil, artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    // MARK: - ContextService

    @Test("ContextService: ffContext 关闭 → capture 返回 nil(隐私默认关)")
    func captureDisabledReturnsNil() {
        let svc = ContextService(
            trackActiveAppProvider: { true },
            frontmostAppProvider: { "com.apple.Xcode" },
            deviceProvider: { ContextService.DeviceContext(outputDeviceName: "Speakers", isHeadphones: false) },
            nowProvider: { makeDate(hour: 14) },
            enabledProvider: { false }
        )
        #expect(svc.isEnabled == false)
        #expect(svc.capture() == nil)
    }

    @Test("ContextService: 开启 + 注入提供者 → 正确 ListeningContext;trackActiveApp 关 → bundleId nil")
    func captureWithProviders() throws {
        // 不记录前台应用:即使 frontmostAppProvider 有值,bundleId 应为 nil。
        let svcNoApp = ContextService(
            trackActiveAppProvider: { false },
            frontmostAppProvider: { "com.apple.Xcode" },
            deviceProvider: { ContextService.DeviceContext(outputDeviceName: "AirPods", isHeadphones: true) },
            nowProvider: { makeDate(hour: 23) },
            enabledProvider: { true }
        )
        let ctx = try #require(svcNoApp.capture())
        #expect(ctx.hour == 23)
        #expect(ctx.frontmostAppBundleId == nil)   // trackActiveApp 关 → 不记录
        #expect(ctx.outputDeviceName == "AirPods")
        #expect(ctx.isHeadphones == true)
        #expect(ctx.timeBand == .lateNight)

        // 记录前台应用:bundleId 应填充。
        let svcApp = ContextService(
            trackActiveAppProvider: { true },
            frontmostAppProvider: { "com.apple.Safari" },
            deviceProvider: { ContextService.DeviceContext(outputDeviceName: nil, isHeadphones: nil) },
            nowProvider: { makeDate(hour: 8) },
            enabledProvider: { true }
        )
        let ctx2 = try #require(svcApp.capture())
        #expect(ctx2.frontmostAppBundleId == "com.apple.Safari")
        #expect(ctx2.timeBand == .morning)
    }

    @Test("ListeningContext encode/decode 往返")
    func contextCodableRoundTrip() {
        let ctx = ListeningContext(hour: 9, dayOfWeek: 3, isWeekend: false,
                                    frontmostAppBundleId: "com.apple.Mail",
                                    outputDeviceName: "MacBook Speakers",
                                    isHeadphones: false)
        let json = ContextService.encode(ctx)
        #expect(json != nil)
        let back = ContextService.decode(json)
        #expect(back == ctx)
    }

    // MARK: - HistoryService 上下文附加

    @Test("HistoryService:终结事件携带 contextSummaryJSON(来自注入的 contextProvider)")
    func historyAttachesContext() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let ctx = ListeningContext(hour: 22, dayOfWeek: 6, isWeekend: true,
                                   frontmostAppBundleId: "com.apple.Xcode",
                                   outputDeviceName: "AirPods", isHeadphones: true)
        let history = HistoryService(modelContainer: container, eventBus: bus,
                                      enabledProvider: { true },
                                      contextProvider: { ctx })
        let s = snap("Context Song")
        bus.post(.trackStarted(s))
        bus.post(.trackCompleted(s, listenedMs: 180000))

        let evs = (try ModelContext(container).fetch(FetchDescriptor<ListeningEvent>()))
        #expect(evs.count == 1)
        let decoded = ContextService.decode(evs[0].contextSummaryJSON)
        #expect(decoded == ctx)
        #expect(history.eventCount() == 1)
    }

    @Test("HistoryService.contextProfiles:聚合 per-app / late-night / headphone / weekend")
    func contextProfilesAggregate() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        // 同一前台应用 Xcode、深夜、耳机、周末的事件。
        let ctx = ListeningContext(hour: 23, dayOfWeek: 7, isWeekend: true,
                                    frontmostAppBundleId: "com.apple.Xcode",
                                    outputDeviceName: "AirPods", isHeadphones: true)
        let history = HistoryService(modelContainer: container, eventBus: bus,
                                      enabledProvider: { true },
                                      contextProvider: { ctx })
        let s1 = snap("Coding Track")
        bus.post(.trackStarted(s1)); bus.post(.trackCompleted(s1, listenedMs: 200000))
        bus.post(.trackStarted(s1)); bus.post(.trackCompleted(s1, listenedMs: 200000))

        let profiles = history.contextProfiles()
        // 至少应有 app:Xcode / lateNight / headphone / weekend 四类。
        let ids = Set(profiles.map(\.id))
        #expect(ids.contains("app:com.apple.Xcode"))
        #expect(ids.contains("band:lateNight"))
        #expect(ids.contains("headphone"))
        #expect(ids.contains("weekend"))
        let appProfile = profiles.first { $0.id == "app:com.apple.Xcode" }!
        #expect(appProfile.playCount == 2)
        #expect(appProfile.topTracks.first?.plays == 2)
    }

    // MARK: - AutomationRule 模型

    @Test("AutomationRule:trigger/conditions/action 往返 + conditionsJSON 编解码")
    func ruleRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let conditions = AutomationConditions(appBundleId: "com.apple.Xcode",
                                              timeBand: .lateNight, source: .local,
                                              isHeadphones: true, isWeekend: nil)
        let rule = AutomationRule(name: "Late-night like", trigger: .trackStarted,
                                  conditions: conditions, action: .likeTrack,
                                  cooldownMs: 5000)
        ctx.insert(rule); try ctx.save()

        let fetched = (try ctx.fetch(FetchDescriptor<AutomationRule>())).first!
        #expect(fetched.trigger == .trackStarted)
        #expect(fetched.action == .likeTrack)
        #expect(fetched.cooldownMs == 5000)
        #expect(fetched.conditions == conditions)
        #expect(fetched.conditions?.appBundleId == "com.apple.Xcode")
        #expect(fetched.conditions?.isWeekend == nil)
    }

    // MARK: - AutomationService.matches(纯函数)

    @Test("matches:无条件恒真;AND 语义;source 匹配;app 无上下文不匹配")
    func matchesSemantics() {
        let snapLocal = snap("L", youtube: false)
        let snapYT = snap("Y", youtube: true)
        let ctx = ListeningContext(hour: 23, dayOfWeek: 7, isWeekend: true,
                                   frontmostAppBundleId: "com.apple.Xcode",
                                   outputDeviceName: "AirPods", isHeadphones: true)

        // 无条件 → 恒真
        #expect(AutomationService.matches(nil, snapshot: snapLocal, context: nil) == true)
        // source 匹配
        #expect(AutomationService.matches(AutomationConditions(source: .local), snapshot: snapLocal, context: nil) == true)
        #expect(AutomationService.matches(AutomationConditions(source: .youtube), snapshot: snapLocal, context: nil) == false)
        // app 条件:无上下文 → 不匹配(绝不伪造)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "com.apple.Xcode"), snapshot: snapLocal, context: nil) == false)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "com.apple.Xcode"), snapshot: snapLocal, context: ctx) == true)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "other"), snapshot: snapLocal, context: ctx) == false)
        // AND 语义:多字段须全满足
        let cond = AutomationConditions(appBundleId: "com.apple.Xcode", timeBand: .lateNight, isHeadphones: true)
        #expect(AutomationService.matches(cond, snapshot: snapLocal, context: ctx) == true)
        let condFail = AutomationConditions(appBundleId: "com.apple.Xcode", timeBand: .morning)
        #expect(AutomationService.matches(condFail, snapshot: snapLocal, context: ctx) == false) // 时段不匹配
        // isWeekend
        #expect(AutomationService.matches(AutomationConditions(isWeekend: true), snapshot: snapLocal, context: ctx) == true)
        #expect(AutomationService.matches(AutomationConditions(isWeekend: false), snapshot: snapLocal, context: ctx) == false)
        // source 不依赖上下文:YouTube 曲目
        #expect(AutomationService.matches(AutomationConditions(source: .youtube), snapshot: snapYT, context: nil) == true)
    }

    // MARK: - AutomationService.cooldownAllows(纯函数)

    @Test("cooldownAllows:nil 冷却恒通过;冷却期内 false;过后 true")
    func cooldownAllowsLogic() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let rule = AutomationRule(name: "R", trigger: .trackStarted, action: .likeTrack,
                                  cooldownMs: 1000)
        ctx.insert(rule); try ctx.save()

        // 无 lastFiredAt → 通过
        #expect(AutomationService.cooldownAllows(rule, now: Date()) == true)

        // 记录触发:0.5s 后仍在 1s 冷却内 → false
        rule.lastFiredAt = Date()
        let within = Date().addingTimeInterval(0.5)
        #expect(AutomationService.cooldownAllows(rule, now: within) == false)
        // 1.5s 后 → true
        let after = Date().addingTimeInterval(1.5)
        #expect(AutomationService.cooldownAllows(rule, now: after) == true)

        // 无冷却(cooldownMs nil)→ 恒通过
        rule.cooldownMs = nil
        #expect(AutomationService.cooldownAllows(rule, now: Date()) == true)
    }

    // MARK: - AutomationService 端到端(事件 → 触发 → 动作 + 冷却)

    @Test("端到端:匹配规则触发动作并写 lastFiredAt;冷却期内不重复;非匹配/禁用规则不触发")
    func endToEndFiring() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()

        // 录音式动作处理器:记录被调用的 (action, snapshot)。
        var fired: [(AutomationAction, UUID)] = []
        let svc = AutomationService(modelContainer: container, eventBus: bus,
                                     contextProvider: { nil },
                                     enabledProvider: { true },
                                     actionHandler: { action, snap in
            fired.append((action, snap.id))
        })

        // 规则1:trackStarted → likeTrack,无冷却。
        let idLike = svc.addRule(name: "Auto-like", trigger: .trackStarted,
                                  action: .likeTrack)
        // 规则2:trackCompleted → addToInbox,1s 冷却。
        let idInbox = svc.addRule(name: "Auto-inbox", trigger: .trackCompleted,
                                   action: .addToInbox, cooldownMs: 1000)
        // 规则3:trackSkipped → playNext,但禁用。
        let idDisabled = svc.addRule(name: "Disabled", trigger: .trackSkipped,
                                     action: .playNext)
        svc.setEnabled(false, id: idDisabled)

        let s = snap("Fire Song")
        bus.post(.trackStarted(s))
        #expect(fired.count == 1)
        #expect(fired[0].0 == .likeTrack)
        #expect(fired[0].1 == s.id)
        // 规则1 lastFiredAt 应已写入。
        let likeRule = svc.allRules().first { $0.id == idLike }!
        #expect(likeRule.lastFiredAt != nil)

        // trackCompleted → addToInbox 触发一次。
        bus.post(.trackCompleted(s, listenedMs: 180000))
        #expect(fired.count == 2)
        #expect(fired[1].0 == .addToInbox)

        // 立即再次 trackCompleted:冷却期内 → 不触发(规则2 1s 冷却)。
        let s2 = snap("Second")
        bus.post(.trackCompleted(s2, listenedMs: 100000))
        #expect(fired.count == 2)   // 仍为 2,冷却阻止

        // trackSkipped:禁用规则 → 不触发。
        bus.post(.trackSkipped(s, listenedMs: 5000))
        #expect(fired.count == 2)
    }

    @Test("ffAutomation 关闭:handle 直接返回,不触发任何动作")
    func flagDisabledNoFire() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        var fired = 0
        let svc = AutomationService(modelContainer: container, eventBus: bus,
                                     contextProvider: { nil },
                                     enabledProvider: { false },
                                     actionHandler: { _, _ in fired += 1 })
        svc.addRule(name: "R", trigger: .trackStarted, action: .likeTrack)
        bus.post(.trackStarted(snap("X")))
        #expect(fired == 0)
        #expect(svc.isEnabled == false)
    }

    @Test("条件匹配:app 条件需上下文;无上下文的事件不触发 app 规则")
    func conditionalFiring() throws {
        // 用独立容器隔离两条规则,避免两个服务共享容器时各自 fetch 到对方规则。
        let bus = PlaybackEventBus()
        var fired = 0
        let ctx = ListeningContext(hour: 23, dayOfWeek: 7, isWeekend: true,
                                   frontmostAppBundleId: "com.apple.Xcode",
                                   outputDeviceName: "AirPods", isHeadphones: true)

        // 有上下文的服务:app 条件匹配 → 触发一次。
        let svc = AutomationService(modelContainer: try makeContainer(), eventBus: bus,
                                     contextProvider: { ctx },
                                     enabledProvider: { true },
                                     actionHandler: { _, _ in fired += 1 })
        svc.addRule(name: "Coding-like", trigger: .trackStarted,
                    conditions: AutomationConditions(appBundleId: "com.apple.Xcode"),
                    action: .likeTrack)
        bus.post(.trackStarted(snap("Match")))
        #expect(fired == 1)

        // 无上下文的服务(独立容器 + 独立总线):同样 app 条件,但 contextProvider 返回 nil → 不触发。
        let bus2 = PlaybackEventBus()
        let svc2 = AutomationService(modelContainer: try makeContainer(), eventBus: bus2,
                                      contextProvider: { nil },
                                      enabledProvider: { true },
                                      actionHandler: { _, _ in fired += 1 })
        svc2.addRule(name: "Coding-like2", trigger: .trackStarted,
                     conditions: AutomationConditions(appBundleId: "com.apple.Xcode"),
                     action: .addToInbox)
        bus2.post(.trackStarted(snap("NoCtx")))
        #expect(fired == 1)   // 无上下文 → svc2 规则不触发;svc 已完成,不再叠加
    }

    // MARK: - helper

    private func makeDate(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 18
        comps.hour = hour; comps.minute = 0
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
}