import Foundation

@Observable
@MainActor
final class PlaybackService {
    let state: PlayerState
    private let engine: any PlayerEngine
    let queue: QueueService
    private(set) var volume: Float = 0.8
    private var completionObserver: Task<Void, Never>?
    private var lastCompletedTrackId: UUID?

    init(engine: any PlayerEngine, queue: QueueService) {
        self.engine = engine
        self.queue = queue
        self.state = engine.state
        engine.setVolume(volume)
        observeCompletion()
    }

    func playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        queue.play(track, context: context, from: from)
        Task { await loadCurrent() }
    }

    func toggle() { engine.toggle() }
    func seek(to time: Double) { engine.seek(to: time) }
    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        engine.setVolume(volume)
    }
    func setEQ(_ bands: [EQBand]) { engine.setEQ(bands) }
    func installSpectrumHandler(_ h: @escaping (SpectrumFrame) -> Void) {
        engine.installSpectrumTap(h)
    }

    func next() {
        guard let item = queue.next() else {
            // .all 边界: 第一次返回 nil, 再调一次即可回到首项
            if queue.repeatMode == .all {
                if let item2 = queue.next() {
                    Task { await load(item2.track) }
                } else {
                    state.isPlaying = false
                }
            } else {
                // .off 到尾或队列为空: 停止
                state.isPlaying = false
            }
            return
        }
        Task { await load(item.track) }
    }

    func previous() {
        guard let item = queue.previous() else { return }
        // 若返回的就是当前正在播放的曲目(已在首位/历史空), 跳过 reload 避免抖动
        if item.track.id == state.track?.id { return }
        Task { await load(item.track) }
    }

    private func loadCurrent() async {
        guard let item = queue.current() else { return }
        await load(item.track)
    }

    private func load(_ track: TrackSnapshot) async {
        state.track = track
        lastCompletedTrackId = nil
        do {
            try await engine.load(track)
            engine.play()
        } catch {
            state.error = .decodingFailed(String(describing: error))
            state.isPlaying = false
        }
    }

    private func observeCompletion() {
        completionObserver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                guard self.state.duration > 0 else { continue }
                guard !self.state.isPlaying else { continue }
                // 已播完(position 抵达 duration)且引擎已停
                if self.state.position >= self.state.duration - 0.05 {
                    // 同一曲目的完成只推进一次, 避免轮询重复触发
                    if self.lastCompletedTrackId == self.state.track?.id { continue }
                    self.lastCompletedTrackId = self.state.track?.id
                    // 队列耗尽(.off 且在最后一首且无插队)则停止
                    if self.queue.repeatMode == .off,
                       self.queue.currentIndex >= self.queue.items.count - 1,
                       self.queue.upNext.isEmpty {
                        self.state.isPlaying = false
                    } else {
                        self.next()
                    }
                }
            }
        }
    }
}