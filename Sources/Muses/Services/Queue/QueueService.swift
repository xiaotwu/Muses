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
    /// Crash recovery: the playing track/position from the last checkpoint. Written by PlaybackService checkpoints.
    var currentTrackId: UUID?
    var lastPositionMs: Double?
    /// Advanced Queue: queue groups (ascending by `order`), persisted into `QueueState.groupsJSON`.
    var groups: [QueueGroup] = []
    /// Focus Mode queue lock: `play()` must not replace the collection; manual next/edit still work.
    var replacementLocked = false

    /// Injected by `MusesApp` after container creation so `persist()`/`restore()` can reach SwiftData.
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

    /// Advances to the next track. `as state` labels how the switched-away current track enters history:
    /// an explicit switch below the listening threshold → `.skipped`, everything else → `.played` (natural completion / switched away after real listening).
    /// `PlaybackService` passes it from the displacement heuristic; the completion path uses the default `.played`.
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

    /// Reorders `items` (the current playback queue). `currentIndex` shifts with the move so the current track stays unchanged.
    func move(from: Int, to: Int) {
        guard items.indices.contains(from) else { return }
        let curID = currentIndex >= 0 && currentIndex < items.count ? items[currentIndex].id : nil
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        if let curID = curID, let idx = items.firstIndex(where: { $0.id == curID }) {
            currentIndex = idx
        }
        persist()
    }

    /// Reorders `upNext`.
    func moveUpNext(from: Int, to: Int) {
        guard upNext.indices.contains(from) else { return }
        upNext.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persist()
    }

    // MARK: - Advanced Queue

    /// Locks/unlocks an entry. Looked up by id across items and upNext (first exclusive hit).
    func toggleLocked(itemId: UUID) {
        if let i = items.firstIndex(where: { $0.id == itemId }) {
            items[i].locked.toggle(); persist(); return
        }
        if let i = upNext.firstIndex(where: { $0.id == itemId }) {
            upNext[i].locked.toggle(); persist()
        }
    }

    // MARK: Groups

    /// Adds a group with `order` = current max + 1 and returns the new group id.
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

    /// Deletes a group: unlinks its items/upNext entries (groupId = nil) before removing the group.
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
        // After the move, renumber `order` to match array indices (0…n-1).
        for i in groups.indices { groups[i].order = i }
        persist()
    }

    // MARK: Insert modes

    /// "Play after current group": inserts the track after the last member of the current track's group in items;
    /// falls back to `playNext` (inserted at the head of upNext) when the current track has no group.
    func playAfterCurrentGroup(_ track: TrackSnapshot) {
        let curGroupId = current()?.groupId
        guard let gid = curGroupId else { playNext(track); return }
        let lastIndex = items.lastIndex(where: { $0.groupId == gid }) ?? currentIndex
        let item = QueueItem(track: track,
                             groupId: gid)
        let insertAt = min(lastIndex + 1, items.count)
        items.insert(item, at: insertAt)
        // If the insertion point is before the current index, shift currentIndex so the current track stays put.
        if insertAt <= currentIndex { currentIndex += 1 }
        persist()
    }

    /// "Add with priority": inserts at the head of upNext with an elevated priority (current max + 1),
    /// so it sorts first under any priority-ordering logic (when enabled).
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

    /// Removes the entry at the given upNext index, pushes it to history labeled `.removed`.
    func removeUpNext(at index: Int) {
        guard upNext.indices.contains(index) else { return }
        var entry = upNext.remove(at: index)
        entry.historyState = .removed
        history.insert(entry, at: 0)
        if history.count > 200 { history.removeLast() }
        persist()
    }

    /// Removes the entry at the given index from items (removing the currently playing item is disallowed), pushing it to history labeled `.removed`.
    func removeItem(at index: Int) {
        guard items.indices.contains(index), index != currentIndex else { return }
        var entry = items.remove(at: index)
        entry.historyState = .removed
        history.insert(entry, at: 0)
        if history.count > 200 { history.removeLast() }
        if index < currentIndex { currentIndex -= 1 }
        persist()
    }

    /// Restores the history entry at the given index to the tail of upNext (clearing its history label) and removes it from history.
    func restoreFromHistory(at index: Int) {
        guard history.indices.contains(index) else { return }
        var entry = history.remove(at: index)
        entry.historyState = nil
        upNext.append(entry)
        persist()
    }

    // MARK: - Persistence

    /// Writes the current queue state to `modelContext` (single-row upsert). No-op without a context.
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

    /// Restores queue state from `modelContext`. No-op without a context or row.
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

    // MARK: - Crash-recovery slot (Listening Sessions)

    /// Writes and persists the crash-recovery slot (`currentTrackId` + `lastPositionMs` in ms).
    /// Called by `SessionService` at checkpoints (10s interval / pause / seek / quit / wake),
    /// acting as the single write entry point to avoid scattered writes. Reuses the existing `persist()` single-row upsert path.
    func checkpointPosition(currentTrackId: UUID?, lastPositionMs: Double?) {
        self.currentTrackId = currentTrackId
        self.lastPositionMs = lastPositionMs
        persist()
    }

    /// Clears the crash-recovery slot (called when the user picks "Start Over" in the launch recovery dialog) so the next launch does not auto-restore.
    func clearCrashRecoverySlots() {
        self.currentTrackId = nil
        self.lastPositionMs = nil
        persist()
    }
}
