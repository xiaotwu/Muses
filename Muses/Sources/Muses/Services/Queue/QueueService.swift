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

    /// 由 `MusesApp` 在容器创建后注入,使 `persist()`/`restore()` 可访问 SwiftData。
    var modelContext: ModelContext?

    func play(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        items = context.map { t in
            QueueItem(id: UUID(), track: t, source: t.youTubeId != nil ? .youtube : .local,
                      queuedAt: .init(), fromContext: from)
        }
        originalOrder = items
        currentIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        upNext.removeAll()
        persist()
    }

    func playNext(_ track: TrackSnapshot) {
        let item = QueueItem(track: track, source: track.youTubeId != nil ? .youtube : .local)
        upNext.insert(item, at: 0)
        persist()
    }

    func addToQueue(_ track: TrackSnapshot) {
        let item = QueueItem(track: track, source: track.youTubeId != nil ? .youtube : .local)
        upNext.append(item)
        persist()
    }

    func current() -> QueueItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    func next() -> QueueItem? {
        if let cur = current() {
            history.insert(cur, at: 0)
            if history.count > 200 { history.removeLast() }
        }

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
            let cur = currentIndex >= 0 ? items[currentIndex] : nil
            items.shuffle()
            if let cur = cur, let idx = items.firstIndex(where: { $0.id == cur.id }) {
                currentIndex = idx
            }
        } else {
            items = originalOrder
            currentIndex = 0
        }
        persist()
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

    // MARK: - Persistence

    /// 将当前队列状态写入 `modelContext`(单行 upsert)。无 context 时为 no-op。
    func persist() {
        guard let ctx = modelContext else { return }
        let encoder = JSONEncoder()
        let itemsJSON = (try? String(data: encoder.encode(items), encoding: .utf8)) ?? "[]"
        let upNextJSON = (try? String(data: encoder.encode(upNext), encoding: .utf8)) ?? "[]"
        let historyJSON = (try? String(data: encoder.encode(history), encoding: .utf8)) ?? "[]"

        let existing = (try? ctx.fetch(FetchDescriptor<QueueState>())) ?? []
        let row: QueueState
        if let found = existing.first(where: { $0.id == QueueState.sharedID }) {
            row = found
        } else {
            row = QueueState(itemsJSON: itemsJSON, currentIndex: currentIndex,
                             upNextJSON: upNextJSON, historyJSON: historyJSON,
                             repeatModeRaw: repeatMode.rawValue, shuffle: shuffle)
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
        currentIndex = row.currentIndex
        if let m = RepeatMode(rawValue: row.repeatModeRaw) { repeatMode = m }
        shuffle = row.shuffle
        originalOrder = items
    }
}
