import Testing
import Foundation
import SwiftData
@testable import Muses

/// Phase 19 — Advanced Queue 验收(对应 Final Spec §10.4):
/// - `QueueGroup` 值类型 + `QueueState.groupsJSON` 往返(单行原子持久化,与 QueueItem 同构);
/// - 分组 CRUD:addGroup / renameGroup / removeGroup(解除条目关联)/ toggleCollapsed / moveGroup;
/// - 锁定项 `locked` 贯穿 persist/restore;
/// - 插入模式:playAfterCurrentGroup(无当前分组降级 playNext)/ addToQueueWithPriority;
/// - 队列历史状态标签:`next(as:)` 记 played/skipped;removeUpNext/removeItem 记 removed;
///   restoreFromHistory 还原并清标签;
/// - 旧 QueueState JSON(无 historyState/locked/groupId/priority/groupsJSON)向后兼容解码。
/// 复用既有桩:无音频引擎,纯 QueueService 逻辑 + in-memory ModelContainer。
@MainActor
@Suite("Phase 19 Advanced Queue")
struct Phase19QueueTests {

    private func makeContainer() throws -> ModelContainer {
        try makeModelContainer(inMemory: true)
    }

    private func snap(_ t: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, filePath: nil, youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil, sampleRate: nil,
                      bitDepth: nil, codec: nil, isLossless: false)
    }

    /// 绑定 modelContext 的 QueueService(用于 persist/restore)。
    private func makeQueue(container: ModelContainer) -> QueueService {
        let q = QueueService()
        q.modelContext = container.mainContext
        return q
    }

    private func queueStateRow(_ container: ModelContainer) -> QueueState? {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<QueueState>()))?
            .first(where: { $0.id == QueueState.sharedID })
    }

    // MARK: - 分组

    @Test("分组 addGroup/toggleCollapsed 持久化往返")
    func groupRoundTrip() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        let g1 = q.addGroup("A")
        let g2 = q.addGroup("B")
        #expect(q.groups.map(\.name) == ["A", "B"])
        #expect(q.groups.map(\.order) == [0, 1])
        q.toggleCollapsed(groupId: g1)
        #expect(q.groups.first(where: { $0.id == g1 })?.collapsed == true)

        // 用第二个 QueueService 从同一容器恢复,验证落库 + groupsJSON 往返。
        let q2 = makeQueue(container: container)
        q2.restore()
        #expect(q2.groups.count == 2)
        #expect(q2.groups.map(\.name) == ["A", "B"])
        #expect(q2.groups.first(where: { $0.id == g1 })?.collapsed == true)
        #expect(q2.groups.first(where: { $0.id == g2 })?.collapsed == false)
    }

    @Test("removeGroup 解除条目 groupId 关联")
    func removeGroupClearsMembership() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        let g = q.addGroup("G")
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.items[0].groupId = g
        q.items[1].groupId = g
        q.persist()
        #expect(q.items.allSatisfy { $0.groupId == g })

        q.removeGroup(id: g)
        #expect(q.groups.isEmpty)
        #expect(q.items.allSatisfy { $0.groupId == nil })
    }

    @Test("moveGroup 重排并按新下标重写 order")
    func moveGroupReindexes() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        let _ = q.addGroup("A"); let _ = q.addGroup("B"); let gC = q.addGroup("C")
        q.moveGroup(from: 2, to: 0)            // C → 首
        #expect(q.groups.map(\.name) == ["C", "A", "B"])
        #expect(q.groups.map(\.order) == [0, 1, 2])
        #expect(q.groups.first(where: { $0.id == gC })?.order == 0)
    }

    @Test("renameGroup 改名并持久化")
    func renameGroup() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        let g = q.addGroup("Old")
        q.renameGroup(id: g, to: "New")
        #expect(q.groups.first(where: { $0.id == g })?.name == "New")
        let q2 = makeQueue(container: container)
        q2.restore()
        #expect(q2.groups.first(where: { $0.id == g })?.name == "New")
    }

    // MARK: - 锁定

    @Test("locked 贯穿 persist/restore")
    func lockedSurvivesPersist() throws {
        let container = try makeContainer()
        let q = makeQueue(container: container)
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.items[0].locked = true
        q.persist()

        let q2 = makeQueue(container: container)
        q2.restore()
        #expect(q2.items.first(where: { $0.track.title == "a" })?.locked == true)
        #expect(q2.items.first(where: { $0.track.title == "b" })?.locked == false)
    }

    @Test("toggleLocked 在 items 与 upNext 中切换")
    func toggleLockedById() {
        let q = QueueService()
        let ctx = [snap("a")]
        q.play(ctx[0], context: ctx, from: .album)
        let upId = UUID()
        q.upNext = [QueueItem(id: upId, track: snap("u"), source: .local)]
        let curId = q.items[0].id
        q.toggleLocked(itemId: curId)
        q.toggleLocked(itemId: upId)
        #expect(q.items[0].locked == true)
        #expect(q.upNext[0].locked == true)
        q.toggleLocked(itemId: curId)        // 再切回
        #expect(q.items[0].locked == false)
    }

    // MARK: - 插入模式

    @Test("playAfterCurrentGroup 插到当前分组最后成员之后;无分组降级 playNext")
    func playAfterCurrentGroup() {
        let q = QueueService()
        let g = UUID()
        let ctx = [snap("a"), snap("b"), snap("c")]
        q.play(ctx[0], context: ctx, from: .album)
        q.items[0].groupId = g
        q.items[1].groupId = g
        q.items[2].groupId = nil
        q.playAfterCurrentGroup(snap("ins"))      // 当前 a 属 g → 插到 b 后(c 前)
        #expect(q.items.map(\.track.title) == ["a", "b", "ins", "c"])
        #expect(q.items[2].groupId == g)
        #expect(q.currentIndex == 0)              // 当前曲目不变

        // 当前无分组 → 降级 playNext(upNext 头)
        q.items[0].groupId = nil
        q.playAfterCurrentGroup(snap("ins2"))
        #expect(q.upNext.first?.track.title == "ins2")
    }

    @Test("addToQueueWithPriority 递增 priority 并插到 upNext 头")
    func addToQueueWithPriority() {
        let q = QueueService()
        q.addToQueueWithPriority(snap("x"))
        q.addToQueueWithPriority(snap("y"))
        #expect(q.upNext.map(\.track.title) == ["y", "x"])
        #expect(q.upNext[0].priority! > q.upNext[1].priority!)
    }

    // MARK: - 历史状态标签

    @Test("next(as:) 默认 .played;传 .skipped 记 skipped")
    func nextHistoryStateTag() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.playNext(snap("x"))
        _ = q.next()                              // 默认 played
        #expect(q.history.first?.historyState == .played)

        q.playNext(snap("y"))
        _ = q.next(as: .skipped)                  // 显式 skipped
        #expect(q.history.first?.historyState == .skipped)
    }

    @Test("removeUpNext / removeItem 推入 history 并记 removed")
    func removeRecordsRemoved() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.upNext = [QueueItem(track: snap("u"), source: .local)]
        q.removeUpNext(at: 0)
        #expect(q.upNext.isEmpty)
        #expect(q.history.first?.track.title == "u")
        #expect(q.history.first?.historyState == .removed)

        // 移除 items 中非当前项(currentIndex=0 → 只能移除 index 1)
        q.removeItem(at: 1)
        #expect(q.items.map(\.track.title) == ["a"])
        #expect(q.history.first?.track.title == "b")
        #expect(q.history.first?.historyState == .removed)
    }

    @Test("removeItem 拒绝移除当前播放项")
    func removeItemRefusesCurrent() {
        let q = QueueService()
        let ctx = [snap("a")]
        q.play(ctx[0], context: ctx, from: .album)
        #expect(q.currentIndex == 0)
        q.removeItem(at: 0)                       // 当前项 → no-op
        #expect(q.items.count == 1)
        #expect(q.history.isEmpty)
    }

    @Test("restoreFromHistory 还原到 upNext 末尾并清掉历史标签")
    func restoreFromHistory() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        q.upNext = [QueueItem(track: snap("u"), source: .local)]
        q.removeUpNext(at: 0)                     // → history(.removed)
        #expect(q.history.first?.historyState == .removed)
        q.restoreFromHistory(at: 0)
        #expect(q.history.isEmpty)
        #expect(q.upNext.last?.track.title == "u")
        #expect(q.upNext.last?.historyState == nil)
    }

    // MARK: - 向后兼容解码

    @Test("旧 QueueState JSON(无新字段)解码为默认值")
    func backwardCompatDecode() throws {
        // 手工构造仅含 Phase 16 之前必需键的 QueueItem JSON(无 locked/groupId/priority/historyState)。
        let itemId = UUID()
        let trackId = UUID()
        let oldTrack: [String: Any] = [
            "id": trackId.uuidString, "title": "Old", "artist": "A",
            "durationSeconds": 1.0, "isLossless": false
        ]
        let oldItem: [String: Any] = [
            "id": itemId.uuidString, "track": oldTrack,
            "source": "local", "queuedAt": 0, "fromContext": "songs"
        ]
        let data = try JSONSerialization.data(withJSONObject: [oldItem])
        let items = try JSONDecoder().decode([QueueItem].self, from: data)
        #expect(items.count == 1)
        #expect(items[0].locked == false)
        #expect(items[0].groupId == nil)
        #expect(items[0].priority == nil)
        #expect(items[0].historyState == nil)     // 缺省 → nil(按 .played 兜底)
    }

    @Test("restore: groupsJSON 缺省 → groups 为空")
    func restoreNilGroupsJSON() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        // 直接插入一行不含 groupsJSON(模拟旧库):init 默认 groupsJSON = nil
        let row = QueueState(itemsJSON: "[]", currentIndex: -1,
                             upNextJSON: "[]", historyJSON: "[]",
                             repeatModeRaw: "off", shuffle: false)
        ctx.insert(row)
        try ctx.save()

        let q = makeQueue(container: container)
        q.restore()
        #expect(q.groups.isEmpty)
    }

    @Test("next() 默认路径不改变既有行为:历史条目无标签时按 played 处理")
    func defaultNextPreservesBehavior() {
        let q = QueueService()
        let ctx = [snap("a"), snap("b")]
        q.play(ctx[0], context: ctx, from: .album)
        let n = q.next()
        #expect(n?.track.title == "b")
        #expect(q.history.first?.track.title == "a")
        #expect(q.history.first?.historyState == .played)
    }
}