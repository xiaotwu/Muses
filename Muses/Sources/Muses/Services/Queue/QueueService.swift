import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class QueueService {
    var items: [QueueItem] = []
    var currentIndex: Int = -1
    var upNext: [QueueItem] = []
    var history: [QueueItem] = []
    var repeatMode: RepeatMode = .off
    var shuffle: Bool = false
    private var originalOrder: [QueueItem] = []
    /// 崩溃恢复用:上次 checkpoint 的播放曲目/位置。Phase 18 由 PlaybackService checkpoint 写入。
    var currentTrackId: UUID?
    var lastPositionMs: Double?
    /// Phase 19 Advanced Queue:队列分组(按 `order` 升序)。持久化进 `QueueState.groupsJSON`。
    var groups: [QueueGroup] = []
    /// Focus Mode queue lock: `play()` must not replace the collection; manual next/edit still work.
    var replacementLocked = false

    /// 由 `MusesApp` 在容器创建后注入,使 `persist()`/`restore()` 可访问 SwiftData。
    var modelContext: ModelContext?

    func play(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        if replacementLocked {
            if let idx = items.firstIndex(where: { $0.track.id == track.id }) {
                currentIndex = idx
                persist()
                return
            }
            playNext(track)
            return
        }
        items = context.map { t in
            QueueItem(id: UUID(), track: t,
                      queuedAt: .init(), fromContext: from)
        }
        originalOrder = items
        currentIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        upNext.removeAll()
        persist()
    }

    func playNext(_ track: TrackSnapshot) {
        let item = QueueItem(track: track)
        upNext.insert(item, at: 0)
        persist()
    }

    func addToQueue(_ track: TrackSnapshot) {
        let item = QueueItem(track: track)
        upNext.append(item)
        persist()
    }

    func current() -> QueueItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    /// 推进到下一首。`as state` 标记被切走的当前曲目如何进入 history:
    /// 用户主动切且听不足阈值 → `.skipped`,其余 → `.played`(自然完成 / 充分收听后切走)。
    /// `PlaybackService` 据位移启发式传入;完成路径用默认 `.played`。
    func next(as state: QueueHistoryState = .played) -> QueueItem? {
        if var cur = current() {
            cur.historyState = state
            history.insert(cur, at: 0)
            if history.count > 200 { history.removeLast() }
        }

        sortUpNextByPriority()
        if !upNext.isEmpty {
            let popped = upNext.removeFirst()
            persist()
            return popped
        }
        guard !items.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return current()
        case .all:
            if currentIndex >= items.count {
                currentIndex = 0
                persist()
                return current()
            }
            let next = currentIndex + 1
            if next < items.count {
                currentIndex = next
                persist()
                return current()
            } else {
                currentIndex = next
                persist()
                return nil
            }
        case .off:
            let next = currentIndex + 1
            guard next < items.count else { return nil }
            currentIndex = next
            persist()
            return current()
        }
    }

    func previous() -> QueueItem? {
        if let h = history.first {
            history.removeFirst()
            if let idx = items.firstIndex(where: { $0.id == h.id }) {
                currentIndex = idx
            }
            persist()
            return h
        }
        guard currentIndex > 0 else { return current() }
        currentIndex -= 1
        persist()
        return current()
    }

    func setRepeat(_ m: RepeatMode) {
        repeatMode = m
        persist()
    }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle {
            originalOrder = items
            let cur = currentIndex >= 0 && currentIndex < items.count ? items[currentIndex] : nil
            shuffleUnlockedItems()
            if let cur = cur, let idx = items.firstIndex(where: { $0.id == cur.id }) {
                currentIndex = idx
            }
        } else {
            let cur = (currentIndex >= 0 && currentIndex < items.count) ? items[currentIndex] : nil
            items = originalOrder
            if let cur, let idx = items.firstIndex(where: { $0.id == cur.id }) {
                currentIndex = idx
            } else if !items.isEmpty {
                currentIndex = min(max(currentIndex, 0), items.count - 1)
            }
        }
        persist()
    }

    /// Next item that will play: Up Next head, else the following collection row, else wrap on Repeat All.
    func peekNext() -> QueueItem? {
        sortUpNextByPriority()
        if let first = upNext.first { return first }
        guard !items.isEmpty else { return nil }
        let following = currentIndex + 1
        if following < items.count { return items[following] }
        if repeatMode == .all { return items.first }
        return nil
    }

    /// 重排 `items`(当前播放队列)。`currentIndex` 随移动调整以保持当前曲目不变。
    func move(from: Int, to: Int) {
        guard items.indices.contains(from) else { return }
        let curID = currentIndex >= 0 && currentIndex < items.count ? items[currentIndex].id : nil
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        if let curID = curID, let idx = items.firstIndex(where: { $0.id == curID }) {
            currentIndex = idx
        }
        persist()
    }

    /// 重排 `upNext`(待播队列)。
    func moveUpNext(from: Int, to: Int) {
        guard upNext.indices.contains(from) else { return }
        upNext.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persist()
    }

    // MARK: - Phase 19 Advanced Queue

    /// 锁定/解锁条目。在 items 与 upNext 中按 id 查找(互斥命中首个)。
    func toggleLocked(itemId: UUID) {
        if let i = items.firstIndex(where: { $0.id == itemId }) {
            items[i].locked.toggle(); persist(); return
        }
        if let i = upNext.firstIndex(where: { $0.id == itemId }) {
            upNext[i].locked.toggle(); persist()
        }
    }

    // MARK: Groups

    /// 新增分组,`order` 取当前最大 +1,返回新分组 id。
    @discardableResult
    func addGroup(_ name: String) -> UUID {
        let id = UUID()
        let order = (groups.map(\.order).max() ?? -1) + 1
        groups.append(QueueGroup(id: id, name: name, order: order))
        persist()
        return id
    }

    func renameGroup(id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
        persist()
    }

    /// 删除分组:解除属于该组的 items/upNext 条目关联(置 groupId = nil),再移除分组。
    func removeGroup(id: UUID) {
        for i in items.indices where items[i].groupId == id { items[i].groupId = nil }
        for i in upNext.indices where upNext[i].groupId == id { upNext[i].groupId = nil }
        groups.removeAll { $0.id == id }
        persist()
    }

    func toggleCollapsed(groupId id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].collapsed.toggle()
        persist()
    }

    func moveGroup(from: Int, to: Int) {
        guard groups.indices.contains(from) else { return }
        groups.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        // 移动后重排 `order`,保持其与数组下标一致(0…n-1)。
        for i in groups.indices { groups[i].order = i }
        persist()
    }

    // MARK: Insert modes

    /// 「Play after current group」:把曲目插入到当前曲目所属分组在 items 中的最后成员之后;
    /// 当前曲目无分组时降级为 `playNext`(插到 upNext 头)。
    func playAfterCurrentGroup(_ track: TrackSnapshot) {
        let curGroupId = current()?.groupId
        guard let gid = curGroupId else { playNext(track); return }
        let lastIndex = items.lastIndex(where: { $0.groupId == gid }) ?? currentIndex
        let item = QueueItem(track: track,
                             groupId: gid)
        let insertAt = min(lastIndex + 1, items.count)
        items.insert(item, at: insertAt)
        // 若插入点在当前之前,currentIndex 后移以保持当前曲目不变。
        if insertAt <= currentIndex { currentIndex += 1 }
        persist()
    }

    /// 「Add with priority」:插到 upNext 头并赋较高 priority(现有最大 +1),
    /// 使其在后续「按优先级排序」逻辑(若启用)中排在最前。
    func addToQueueWithPriority(_ track: TrackSnapshot) {
        let p = (upNext.compactMap(\.priority).max() ?? 0) + 1
        let item = QueueItem(track: track,
                             priority: p)
        upNext.insert(item, at: 0)
        sortUpNextByPriority()
        persist()
    }

    private func sortUpNextByPriority() {
        guard upNext.contains(where: { $0.priority != nil }) else { return }
        upNext.sort { ($0.priority ?? 0) > ($1.priority ?? 0) }
    }

    /// Shuffle unlocked rows in place; locked rows keep their indices.
    private func shuffleUnlockedItems() {
        var unlocked = items.filter { !$0.locked }
        unlocked.shuffle()
        var next = 0
        for i in items.indices where !items[i].locked {
            items[i] = unlocked[next]
            next += 1
        }
    }

    // MARK: Remove → history(.removed) + restore

    /// 从 upNext 移除指定下标条目,推入 history 并标记 `.removed`。
    func removeUpNext(at index: Int) {
        guard upNext.indices.contains(index) else { return }
        var entry = upNext.remove(at: index)
        entry.historyState = .removed
        history.insert(entry, at: 0)
        if history.count > 200 { history.removeLast() }
        persist()
    }

    /// 从 items 移除指定下标条目(禁止移除当前播放项),推入 history 并标记 `.removed`。
    func removeItem(at index: Int) {
        guard items.indices.contains(index), index != currentIndex else { return }
        var entry = items.remove(at: index)
        entry.historyState = .removed
        history.insert(entry, at: 0)
        if history.count > 200 { history.removeLast() }
        if index < currentIndex { currentIndex -= 1 }
        persist()
    }

    /// 把 history 指定下标条目还原回 upNext 末尾(清掉历史标签),并从 history 移除。
    func restoreFromHistory(at index: Int) {
        guard history.indices.contains(index) else { return }
        var entry = history.remove(at: index)
        entry.historyState = nil
        upNext.append(entry)
        persist()
    }

    // MARK: - Persistence

    /// 将当前队列状态写入 `modelContext`(单行 upsert)。无 context 时为 no-op。
    func persist() {
        guard let ctx = modelContext else { return }
        let encoder = JSONEncoder()
        let itemsJSON = (try? String(data: encoder.encode(items), encoding: .utf8)) ?? "[]"
        let upNextJSON = (try? String(data: encoder.encode(upNext), encoding: .utf8)) ?? "[]"
        let historyJSON = (try? String(data: encoder.encode(history), encoding: .utf8)) ?? "[]"
        let groupsJSON = (try? String(data: encoder.encode(groups), encoding: .utf8)) ?? "[]"

        let existing = (try? ctx.fetch(FetchDescriptor<QueueState>())) ?? []
        let row: QueueState
        if let found = existing.first(where: { $0.id == QueueState.sharedID }) {
            row = found
        } else {
            row = QueueState(itemsJSON: itemsJSON, currentIndex: currentIndex,
                             upNextJSON: upNextJSON, historyJSON: historyJSON,
                             repeatModeRaw: repeatMode.rawValue, shuffle: shuffle,
                             currentTrackId: currentTrackId, lastPositionMs: lastPositionMs,
                             groupsJSON: groupsJSON)
            ctx.insert(row)
            try? ctx.save()
            return
        }
        row.itemsJSON = itemsJSON
        row.currentIndex = currentIndex
        row.upNextJSON = upNextJSON
        row.historyJSON = historyJSON
        row.repeatModeRaw = repeatMode.rawValue
        row.shuffle = shuffle
        row.currentTrackId = currentTrackId
        row.lastPositionMs = lastPositionMs
        row.groupsJSON = groupsJSON
        row.savedAt = .init()
        try? ctx.save()
    }

    /// 从 `modelContext` 恢复队列状态。无 context 或无行时为 no-op。
    func restore() {
        guard let ctx = modelContext else { return }
        let rows = (try? ctx.fetch(FetchDescriptor<QueueState>())) ?? []
        guard let row = rows.first(where: { $0.id == QueueState.sharedID }) else { return }
        let decoder = JSONDecoder()
        items = (try? decoder.decode([QueueItem].self, from: Data(row.itemsJSON.utf8))) ?? []
        upNext = (try? decoder.decode([QueueItem].self, from: Data(row.upNextJSON.utf8))) ?? []
        history = (try? decoder.decode([QueueItem].self, from: Data(row.historyJSON.utf8))) ?? []
        let decodedGroups = (row.groupsJSON.flatMap { try? decoder.decode([QueueGroup].self, from: Data($0.utf8)) }) ?? []
        groups = decodedGroups.sorted { $0.order < $1.order }
        currentIndex = row.currentIndex
        if let m = RepeatMode(rawValue: row.repeatModeRaw) { repeatMode = m }
        shuffle = row.shuffle
        currentTrackId = row.currentTrackId
        lastPositionMs = row.lastPositionMs
        originalOrder = items
    }

    // MARK: - 崩溃恢复槽位(Phase 18 Listening Sessions)

    /// 把崩溃恢复槽(`currentTrackId` + `lastPositionMs`,毫秒)写入并持久化。
    /// 由 `SessionService` 在 checkpoint(周期 10s / pause / seek / 退出 / 唤醒)时调用,
    /// 作为单一写入入口,避免多处置写。复用既有 `persist()` 单行 upsert 路径。
    func checkpointPosition(currentTrackId: UUID?, lastPositionMs: Double?) {
        self.currentTrackId = currentTrackId
        self.lastPositionMs = lastPositionMs
        persist()
    }

    /// 清空崩溃恢复槽(用户在启动恢复对话框选择「重新开始」时调用),使下次启动不自动恢复。
    func clearCrashRecoverySlots() {
        self.currentTrackId = nil
        self.lastPositionMs = nil
        persist()
    }
}
