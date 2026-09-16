import Testing
import Foundation
import SwiftData
@testable import Muses

/// Contextual listening acceptance.
@MainActor
@Suite("Contextual Listening")
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

    // MARK: - helper

    private func makeDate(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 18
        comps.hour = hour; comps.minute = 0
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
}
