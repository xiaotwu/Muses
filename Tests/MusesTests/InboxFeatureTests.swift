import Testing
import Foundation
import SwiftData
@testable import Muses

/// Music Inbox acceptance (Final Spec §10.6):
/// - `InboxItem` @Model persists + state/source computed properties;
/// - `InboxService`: add (dedupe / feature-flag gating) / remove / accept (→ like) / reject /
///   snooze (→ unheard once due) / addNote; subscribes to the event bus `.trackStarted → .listening`;
/// - the `ffInbox` feature flag: when off, add is a no-op but the subscription stays registered.
@MainActor
@Suite("Inbox")
struct InboxFeatureTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ t: String, id: UUID = UUID()) -> TrackSnapshot {
        TrackSnapshot(id: id, title: t, artist: "A", albumTitle: nil,
                      durationSeconds: 1, youTubeId: "test-video",
                      artworkUrl: nil, sampleRate: nil,
                      bitDepth: nil, codec: nil, isLossless: false)
    }

    /// An InboxService with the flag on (the default enabledProvider reads false from UserDefaults; tests inject true).
    private func makeInbox(container: ModelContainer, bus: PlaybackEventBus = PlaybackEventBus(),
                           enabled: Bool = true) -> InboxService {
        InboxService(modelContainer: container, eventBus: bus, enabledProvider: { enabled })
    }

    private func fetchInbox(_ container: ModelContainer) -> [InboxItem] {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<InboxItem>())) ?? []
    }

    // MARK: - Model

    @Test("InboxItem 持久化往返 + state/source 计算属性")
    func inboxRoundTrip() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let item = InboxItem(trackId: UUID(), trackTitle: "T", artist: "A",
                             albumTitle: nil, durationSeconds: 1, youTubeId: "test-video",
                             artworkUrl: nil, source: .youTubeImport,
                             state: .snoozed, snoozeUntil: Date().addingTimeInterval(3600))
        ctx.insert(item)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<InboxItem>()).first
        #expect(fetched?.state == .snoozed)
        #expect(fetched?.source == .youTubeImport)
        #expect(fetched?.snoozeUntil != nil)
    }

    @Test("InboxItem 表已加入 schema(空查询成功)")
    func schemaIncludesInbox() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let items = try ctx.fetch(FetchDescriptor<InboxItem>())
        #expect(items.isEmpty)
    }

    // MARK: - add / dedupe / flag

    @Test("add 新建 .unheard 条目;同 trackId 未终态时去重")
    func addAndDedupe() throws {
        let container = try makeContainer()
        let inbox = makeInbox(container: container)
        let id = UUID()
        let added = inbox.add(snap("T", id: id))
        #expect(added != nil)
        #expect(fetchInbox(container).count == 1)
        #expect(fetchInbox(container).first?.state == .unheard)

        // Same trackId not in a terminal state → skip
        let again = inbox.add(snap("T", id: id))
        #expect(again == nil)
        #expect(fetchInbox(container).count == 1)
    }

    @Test("ffInbox 关闭:add 为 no-op,不落库")
    func addNoOpWhenDisabled() throws {
        let container = try makeContainer()
        let inbox = makeInbox(container: container, enabled: false)
        let added = inbox.add(snap("T"))
        #expect(added == nil)
        #expect(fetchInbox(container).isEmpty)
    }

    // MARK: - State machine

    @Test("reject → .rejected;remove 删除条目")
    func rejectAndRemove() throws {
        let container = try makeContainer()
        let inbox = makeInbox(container: container)
        let id = inbox.add(snap("T"))!
        inbox.reject(id: id)
        #expect(fetchInbox(container).first?.state == .rejected)

        inbox.remove(id: id)
        #expect(fetchInbox(container).isEmpty)
    }

    @Test("snooze → .snoozed;到期 restoreDueSnoozes → .unheard;未到期保持")
    func snoozeAndRestore() throws {
        let container = try makeContainer()
        let inbox = makeInbox(container: container)
        let id = inbox.add(snap("T"))!
        let past = Date().addingTimeInterval(-60)
        let future = Date().addingTimeInterval(3600)

        inbox.snooze(id: id, until: future)
        #expect(fetchInbox(container).first?.state == .snoozed)
        inbox.restoreDueSnoozes(now: Date())           // not due yet → unchanged
        #expect(fetchInbox(container).first?.state == .snoozed)

        inbox.snooze(id: id, until: past)
        inbox.restoreDueSnoozes(now: Date())           // due → unheard
        let row = fetchInbox(container).first
        #expect(row?.state == .unheard)
        #expect(row?.snoozeUntil == nil)
    }

    @Test("addNote 写入并清空")
    func addNote() throws {
        let container = try makeContainer()
        let inbox = makeInbox(container: container)
        let id = inbox.add(snap("T"))!
        inbox.addNote(id: id, note: "hello")
        #expect(fetchInbox(container).first?.notes == "hello")
        inbox.addNote(id: id, note: "")
        #expect(fetchInbox(container).first?.notes == nil)
    }

    // MARK: - Event bus → listening

    @Test("trackStarted 命中 unheard 条目 → .listening;不匹配则不动")
    func trackStartedMarksListening() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let inbox = makeInbox(container: container, bus: bus)
        let trackId = UUID()
        let id = inbox.add(snap("T", id: trackId))!
        _ = id

        bus.post(.trackStarted(snap("T", id: trackId)))
        #expect(fetchInbox(container).first?.state == .listening)

        // A non-matching trackId leaves existing entries alone
        bus.post(.trackStarted(snap("Other", id: UUID())))
        #expect(fetchInbox(container).first?.state == .listening)
    }

    @Test("已终态(accepted)条目不被 trackStarted 改回 listening")
    func acceptedNotReopened() throws {
        let container = try makeContainer()
        let bus = PlaybackEventBus()
        let inbox = makeInbox(container: container, bus: bus)
        let trackId = UUID()
        let id = inbox.add(snap("T", id: trackId))!
        inbox.accept(id: id, library: nil)            // no library → only mark accepted
        #expect(fetchInbox(container).first?.state == .accepted)

        bus.post(.trackStarted(snap("T", id: trackId)))
        #expect(fetchInbox(container).first?.state == .accepted)
    }

    // MARK: - accept → like

    @Test("accept 置 .accepted 并把对应 Track.liked 置 true")
    func acceptLikesTrack() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let trackId = UUID()
        let track = Track(id: trackId, title: "T", artist: "A", youTubeId: "test-video")
        ctx.insert(track)
        try ctx.save()

        let library = LibraryService(modelContainer: container)
        let inbox = makeInbox(container: container)
        let id = inbox.add(snap("T", id: trackId))!

        #expect(library.isLiked(id: trackId) == false)
        inbox.accept(id: id, library: library)
        #expect(fetchInbox(container).first?.state == .accepted)
        #expect(library.isLiked(id: trackId) == true)

        // Accepting again while already liked must not unlike (the implementation only toggles like when not yet liked).
        // Add a second item with the same trackId (accepted is terminal, so re-adding is allowed), accept it, and liked must still be true.
        let id2 = inbox.add(snap("T2", id: trackId))
        #expect(id2 != nil)
        inbox.accept(id: id2!, library: library)
        #expect(library.isLiked(id: trackId) == true)
    }
}
