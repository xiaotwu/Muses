import Testing
import Foundation
import SwiftData
@testable import Muses

/// Focus Mode acceptance (Final Spec §10.9).
/// Covers: the FocusSession model round trip, FocusService flag no-op, start/stop state transitions + persistence +
/// the event bus + queue locking + Pomodoro configuration + expiry behavior storage. Actual countdown expiry is runtime behavior;
/// bounded by Task.sleep, it is not waited for in headless tests (§15: never fabricate).
@MainActor
@Suite("Focus Mode")
struct FocusFeatureTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    // MARK: - FocusSession model

    @Test("FocusSession:status 编解码 + 默认 active")
    func modelRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let s = FocusSession(plannedDurationMs: 25 * 60 * 1000, status: .active)
        ctx.insert(s); try ctx.save()
        let fetched = (try ctx.fetch(FetchDescriptor<FocusSession>())).first!
        #expect(fetched.status == .active)
        #expect(fetched.plannedDurationMs == 25 * 60 * 1000)
        #expect(fetched.endedAt == nil)
        fetched.status = .completed
        try ctx.save()
        #expect(FocusStatus(rawValue: fetched.statusRaw) == .completed)
    }

    // MARK: - FocusService flag no-op

    @Test("ffFocusMode 关闭:start 为 no-op,无 FocusSession 行,isActive 保持 false")
    func flagDisabledNoOp() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let playback = PlaybackService(youtubeEngine: RecordingEngine(), queue: QueueService(),
                                        library: LibraryService(modelContainer: container))
        var events: [PlaybackEvent] = []
        bus.subscribe { events.append($0) }
        let svc = FocusService(modelContainer: container, eventBus: bus, playback: playback,
                                enabledProvider: { false })
        svc.start(minutes: 25)
        #expect(svc.isActive == false)
        #expect(svc.isEnabled == false)
        #expect(events.isEmpty)   // no focusSessionStarted emitted
        let count = (try? ModelContext(container).fetchCount(FetchDescriptor<FocusSession>())) ?? -1
        #expect(count == 0)
    }

    // MARK: - start / stop state + persistence + events

    @Test("start(minutes:):isActive + FocusSession 行(active)+ focusSessionStarted 事件")
    func startPersistsAndPosts() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let playback = makePlayback(container)
        var started = 0, ended = 0
        bus.subscribe { e in
            switch e { case .focusSessionStarted: started += 1
                       case .focusSessionEnded: ended += 1
                       default: break }
        }
        let svc = FocusService(modelContainer: container, eventBus: bus, playback: playback,
                                enabledProvider: { true })
        svc.start(minutes: 25, queueLocked: true, expiration: .pause)
        #expect(svc.isActive == true)
        #expect(svc.isQueueLocked == true)
        #expect(svc.expiration == .pause)
        #expect(svc.totalSeconds == 25 * 60)
        #expect(svc.remainingSeconds == 25 * 60)
        #expect(svc.activeSessionId != nil)
        #expect(started == 1)
        let row = (try ModelContext(container).fetch(FetchDescriptor<FocusSession>())).first!
        #expect(row.status == .active)
        #expect(row.plannedDurationMs == 25 * 60 * 1000)
        #expect(row.endedAt == nil)

        svc.stop()
        #expect(svc.isActive == false)
        #expect(svc.isQueueLocked == false)
        #expect(svc.activeSessionId == nil)
        #expect(ended == 1)
        let row2 = (try ModelContext(container).fetch(FetchDescriptor<FocusSession>())).first!
        #expect(row2.endedAt != nil)
        #expect(row2.status == .completed)
    }

    @Test("start(minutes: nil):无时限,totalSeconds=0,isActive true")
    func startNoTimer() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = FocusService(modelContainer: container, eventBus: bus,
                                playback: makePlayback(container), enabledProvider: { true })
        svc.start(minutes: nil)
        #expect(svc.isActive == true)
        #expect(svc.totalSeconds == 0)
        #expect(svc.remainingSeconds == 0)
        let row = (try ModelContext(container).fetch(FetchDescriptor<FocusSession>())).first!
        #expect(row.plannedDurationMs == nil)
        svc.stop()
    }

    // MARK: - Pomodoro

    @Test("start(pomodoro: true):isPomodoro + 25min focus 阶段")
    func pomodoroConfig() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let svc = FocusService(modelContainer: container, eventBus: bus,
                                playback: makePlayback(container), enabledProvider: { true })
        svc.start(minutes: 99, queueLocked: false, expiration: .keepPlaying, pomodoro: true)
        #expect(svc.isPomodoro == true)
        #expect(svc.pomodoroPhase == .focus)
        #expect(svc.totalSeconds == 25 * 60)   // pomodoro ignores the passed minutes
        #expect(svc.expiration == .keepPlaying)
        svc.stop()
        #expect(svc.isPomodoro == false)
    }

    // MARK: - remainingFormatted

    @Test("remainingFormatted:M:SS / H:MM:SS")
    func remainingFormatted() throws {
        let container = try makeContainer()
        let svc = FocusService(modelContainer: container, eventBus: PlaybackEventBus(),
                                playback: makePlayback(container), enabledProvider: { true })
        svc.start(minutes: 1)   // 60s
        #expect(svc.remainingFormatted == "1:00")
        svc.stop()
        svc.start(minutes: 90)  // 5400s
        #expect(svc.remainingFormatted == "1:30:00")
        svc.stop()
    }

    // MARK: - helpers

    private func makePlayback(_ container: ModelContainer) -> PlaybackService {
        PlaybackService(youtubeEngine: RecordingEngine(), queue: QueueService(),
                        library: LibraryService(modelContainer: container))
    }
}
