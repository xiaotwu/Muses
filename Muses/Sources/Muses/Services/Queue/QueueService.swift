import Foundation
import Observation

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

    func play(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        items = context.map { t in
            QueueItem(id: UUID(), track: t, source: t.youTubeId != nil ? .youtube : .local,
                      queuedAt: .init(), fromContext: from)
        }
        originalOrder = items
        currentIndex = context.firstIndex(where: { $0.id == track.id }) ?? 0
        upNext.removeAll()
    }

    func playNext(_ track: TrackSnapshot) {
        let item = QueueItem(track: track, source: track.youTubeId != nil ? .youtube : .local)
        upNext.insert(item, at: 0)
    }

    func addToQueue(_ track: TrackSnapshot) {
        let item = QueueItem(track: track, source: track.youTubeId != nil ? .youtube : .local)
        upNext.append(item)
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
            return upNext.removeFirst()
        }
        guard !items.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return current()
        case .all:
            if currentIndex >= items.count {
                currentIndex = 0
                return current()
            }
            let next = currentIndex + 1
            if next < items.count {
                currentIndex = next
                return current()
            } else {
                currentIndex = next
                return nil
            }
        case .off:
            let next = currentIndex + 1
            guard next < items.count else { return nil }
            currentIndex = next
            return current()
        }
    }

    func previous() -> QueueItem? {
        if let h = history.first {
            history.removeFirst()
            return h
        }
        guard currentIndex > 0 else { return current() }
        currentIndex -= 1
        return current()
    }

    func setRepeat(_ m: RepeatMode) { repeatMode = m }

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
    }
}
