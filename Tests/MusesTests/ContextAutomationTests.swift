import Testing
import Foundation
import SwiftData
@testable import Muses

/// Contextual Listening + Automation acceptance (Final Spec §10.2 Feature 2 / §12 Feature 12).
@MainActor
@Suite("Phase 23 Context & Automation")
struct ContextAutomationTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ title: String, id: UUID = UUID(), youtube: Bool = true,
                      duration: Double = 200) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: "A", albumTitle: nil,
                      durationSeconds: duration, youTubeId: youtube ? "yt123" : "yt-fallback", artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    // MARK: - ContextService

    @Test("ContextService: ffContext disabled → capture returns nil")
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

    @Test("ContextService: enabled with providers returns ListeningContext; trackActiveApp off keeps bundleId nil")
    func captureWithProviders() throws {
        // Do not record the frontmost app: even when frontmostAppProvider has a value, bundleId must stay nil.
        let svcNoApp = ContextService(
            trackActiveAppProvider: { false },
            frontmostAppProvider: { "com.apple.Xcode" },
            deviceProvider: { ContextService.DeviceContext(outputDeviceName: "AirPods", isHeadphones: true) },
            nowProvider: { makeDate(hour: 23) },
            enabledProvider: { true }
        )
        let ctx = try #require(svcNoApp.capture())
        #expect(ctx.hour == 23)
        #expect(ctx.frontmostAppBundleId == nil)   // trackActiveApp off → not recorded
        #expect(ctx.outputDeviceName == "AirPods")
        #expect(ctx.isHeadphones == true)
        #expect(ctx.timeBand == .lateNight)

        // Record the frontmost app: bundleId should be populated.
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

    @Test("ListeningContext encode/decode round trip")
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

    // MARK: - HistoryService context attachment

    @Test("HistoryService: terminal event carries contextSummaryJSON from contextProvider")
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

    @Test("HistoryService.contextProfiles: aggregates per-app, late-night, headphone, weekend")
    func contextProfilesAggregate() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        // Events sharing the same frontmost app Xcode, late night, headphones, weekend.
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
        // Expect at least four categories: app:Xcode / lateNight / headphone / weekend.
        let ids = Set(profiles.map(\.id))
        #expect(ids.contains("app:com.apple.Xcode"))
        #expect(ids.contains("band:lateNight"))
        #expect(ids.contains("headphone"))
        #expect(ids.contains("weekend"))
        let appProfile = profiles.first { $0.id == "app:com.apple.Xcode" }!
        #expect(appProfile.playCount == 2)
        #expect(appProfile.topTracks.first?.plays == 2)
    }

    // MARK: - AutomationRule model

    @Test("AutomationRule: trigger/conditions/action round trip and conditionsJSON coding")
    func ruleRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let conditions = AutomationConditions(appBundleId: "com.apple.Xcode",
                                              timeBand: .lateNight,
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

    // MARK: - AutomationService.matches (pure function)

    @Test("matches: no conditions, AND semantics, and missing context")
    func matchesSemantics() {
        let snapshot = snap("Y", youtube: true)
        let ctx = ListeningContext(hour: 23, dayOfWeek: 7, isWeekend: true,
                                   frontmostAppBundleId: "com.apple.Xcode",
                                   outputDeviceName: "AirPods", isHeadphones: true)

        // No conditions → always true
        #expect(AutomationService.matches(nil, snapshot: snapshot, context: nil) == true)
        // app condition with no context → no match (never fabricate a match)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "com.apple.Xcode"), snapshot: snapshot, context: nil) == false)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "com.apple.Xcode"), snapshot: snapshot, context: ctx) == true)
        #expect(AutomationService.matches(AutomationConditions(appBundleId: "other"), snapshot: snapshot, context: ctx) == false)
        // AND semantics: every field must match
        let cond = AutomationConditions(appBundleId: "com.apple.Xcode", timeBand: .lateNight, isHeadphones: true)
        #expect(AutomationService.matches(cond, snapshot: snapshot, context: ctx) == true)
        let condFail = AutomationConditions(appBundleId: "com.apple.Xcode", timeBand: .morning)
        #expect(AutomationService.matches(condFail, snapshot: snapshot, context: ctx) == false) // time-of-day mismatch
        // isWeekend
        #expect(AutomationService.matches(AutomationConditions(isWeekend: true), snapshot: snapshot, context: ctx) == true)
        #expect(AutomationService.matches(AutomationConditions(isWeekend: false), snapshot: snapshot, context: ctx) == false)
    }

    // MARK: - AutomationService.cooldownAllows (pure function)

    @Test("cooldownAllows: nil cooldown passes; false inside cooldown; true after")
    func cooldownAllowsLogic() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let rule = AutomationRule(name: "R", trigger: .trackStarted, action: .likeTrack,
                                  cooldownMs: 1000)
        ctx.insert(rule); try ctx.save()

        // No lastFiredAt → allowed
        #expect(AutomationService.cooldownAllows(rule, now: Date()) == true)

        // Record a firing: 0.5s later, still inside the 1s cooldown → false
        rule.lastFiredAt = Date()
        let within = Date().addingTimeInterval(0.5)
        #expect(AutomationService.cooldownAllows(rule, now: within) == false)
        // After 1.5s → true
        let after = Date().addingTimeInterval(1.5)
        #expect(AutomationService.cooldownAllows(rule, now: after) == true)

        // No cooldown (cooldownMs nil) → always allowed
        rule.cooldownMs = nil
        #expect(AutomationService.cooldownAllows(rule, now: Date()) == true)
    }

    // MARK: - AutomationService end to end (event → trigger → action + cooldown)

    @Test("End to end: matching rule triggers action, records lastFiredAt, enforces cooldown, ignores disabled rules")
    func endToEndFiring() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()

        // Recording action handler: captures every (action, snapshot) invocation.
        var fired: [(AutomationAction, UUID)] = []
        let svc = AutomationService(modelContainer: container, eventBus: bus,
                                     contextProvider: { nil },
                                     enabledProvider: { true },
                                     actionHandler: { action, snap in
            fired.append((action, snap.id))
        })

        // Rule 1: trackStarted → likeTrack, no cooldown.
        let idLike = svc.addRule(name: "Auto-like", trigger: .trackStarted,
                                  action: .likeTrack)
        // Rule 2: trackCompleted → addToInbox, 1s cooldown.
        _ = svc.addRule(name: "Auto-inbox", trigger: .trackCompleted,
                        action: .addToInbox, cooldownMs: 1000)
        // Rule 3: trackSkipped → playNext, but disabled.
        let idDisabled = svc.addRule(name: "Disabled", trigger: .trackSkipped,
                                     action: .playNext)
        svc.setEnabled(false, id: idDisabled)

        let s = snap("Fire Song")
        bus.post(.trackStarted(s))
        #expect(fired.count == 1)
        #expect(fired[0].0 == .likeTrack)
        #expect(fired[0].1 == s.id)
        // Rule 1's lastFiredAt should now be written.
        let likeRule = svc.allRules().first { $0.id == idLike }!
        #expect(likeRule.lastFiredAt != nil)

        // trackCompleted → addToInbox fires once.
        bus.post(.trackCompleted(s, listenedMs: 180000))
        #expect(fired.count == 2)
        #expect(fired[1].0 == .addToInbox)

        // Fire trackCompleted again immediately: inside the cooldown → no trigger (rule 2 has a 1s cooldown).
        let s2 = snap("Second")
        bus.post(.trackCompleted(s2, listenedMs: 100000))
        #expect(fired.count == 2)   // still 2; the cooldown blocked it

        // trackSkipped: disabled rule → no trigger.
        bus.post(.trackSkipped(s, listenedMs: 5000))
        #expect(fired.count == 2)
    }

    @Test("ffAutomation disabled: handle returns immediately without triggering actions")
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

    @Test("Condition matching: app condition requires context; event without context does not trigger rule")
    func conditionalFiring() throws {
        // Use separate containers to isolate the two rules, so services sharing one container cannot fetch each other's rules.
        let bus = PlaybackEventBus()
        var fired = 0
        let ctx = ListeningContext(hour: 23, dayOfWeek: 7, isWeekend: true,
                                   frontmostAppBundleId: "com.apple.Xcode",
                                   outputDeviceName: "AirPods", isHeadphones: true)

        // Service with context: the app condition matches → fires once.
        let svc = AutomationService(modelContainer: try makeContainer(), eventBus: bus,
                                     contextProvider: { ctx },
                                     enabledProvider: { true },
                                     actionHandler: { _, _ in fired += 1 })
        svc.addRule(name: "Coding-like", trigger: .trackStarted,
                    conditions: AutomationConditions(appBundleId: "com.apple.Xcode"),
                    action: .likeTrack)
        bus.post(.trackStarted(snap("Match")))
        #expect(fired == 1)

        // Service without context (own container + own bus): the same app condition, but contextProvider returns nil → no trigger.
        let bus2 = PlaybackEventBus()
        let svc2 = AutomationService(modelContainer: try makeContainer(), eventBus: bus2,
                                      contextProvider: { nil },
                                      enabledProvider: { true },
                                      actionHandler: { _, _ in fired += 1 })
        svc2.addRule(name: "Coding-like2", trigger: .trackStarted,
                     conditions: AutomationConditions(appBundleId: "com.apple.Xcode"),
                     action: .addToInbox)
        bus2.post(.trackStarted(snap("NoCtx")))
        #expect(fired == 1)   // without context svc2's rule does not fire; svc already fired, so no additional firing
    }

    // MARK: - helper

    private func makeDate(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 18
        comps.hour = hour; comps.minute = 0
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
}
