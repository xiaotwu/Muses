import Foundation

@Observable
@MainActor
final class PlaybackService {
    /// 统一对外暴露的播放状态:UI 绑定 `playback.state.position` 等。
    /// 计算属性委托到当前引擎的 `state`,保证 `@Observable` 追踪:
    /// 读取 `currentEngine`(存储属性)+ 引擎 `state` 上的可观察字段。
    var state: PlayerState { currentEngine?.state ?? localEngine.state }
    private let localEngine: any PlayerEngine
    private let youtubeEngine: any PlayerEngine
    /// 当前活跃引擎。默认 `localEngine`(本地是主播放模式)。
    /// 切换曲目时按 `track.youTubeId` 选择 local / youtube 引擎。
    private var currentEngine: (any PlayerEngine)?
    /// 频谱处理器缓存:跨引擎切换时需在新引擎上重新安装。
    private var spectrumHandler: ((SpectrumFrame) -> Void)?
    let queue: QueueService
    private(set) var volume: Float = 0.8
    private var completionObserver: Task<Void, Never>?
    private var lastCompletedTrackId: UUID?

    init(localEngine: any PlayerEngine, youtubeEngine: any PlayerEngine, queue: QueueService) {
        self.localEngine = localEngine
        self.youtubeEngine = youtubeEngine
        self.queue = queue
        // 本地是主播放模式,默认指向 localEngine。
        self.currentEngine = localEngine
        localEngine.setVolume(volume)
        youtubeEngine.setVolume(volume)
        setupCompletionHandlers()
        observeCompletion()
    }

    /// 设置引擎完成回调:当前曲目播完时触发无缝推进。
    private func setupCompletionHandlers() {
        localEngine.onCompletion = { [weak self] in
            self?.handleEngineCompletion()
        }
        youtubeEngine.onCompletion = { [weak self] in
            self?.handleEngineCompletion()
        }
    }

    /// 引擎完成回调:优先尝试无缝切换(playPrepared),失败则回退到 load。
    private func handleEngineCompletion() {
        // 同一曲目的完成只推进一次
        if lastCompletedTrackId == state.track?.id { return }
        lastCompletedTrackId = state.track?.id

        // 队列耗尽(.off 且在最后一首且无插队)则停止
        if queue.repeatMode == .off,
           queue.currentIndex >= queue.items.count - 1,
           queue.upNext.isEmpty {
            state.isPlaying = false
            return
        }

        // 尝试无缝切换
        if currentEngine?.playPrepared() == true {
            // 无缝成功:推进队列到新当前曲目
            _ = queue.next()
            // 预加载下一首
            prepareNext()
        } else {
            // 无预加载(YouTube 或无下一首):回退到 load
            next()
        }
    }

    /// 预加载队列中的下一首到当前引擎(本地曲目的无缝前置条件)。
    private func prepareNext() {
        guard let nextItem = queue.upNext.first else {
            // .all 模式且 upNext 空:预加载队列首项
            if queue.repeatMode == .all, let first = queue.items.first {
                Task { await currentEngine?.prepare(first.track) }
            }
            return
        }
        Task { await currentEngine?.prepare(nextItem.track) }
    }

    func playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        queue.play(track, context: context, from: from)
        Task { await loadCurrent() }
    }

    func toggle() { currentEngine?.toggle() }
    func pause() { currentEngine?.pause() }
    func seek(to time: Double) { currentEngine?.seek(to: time) }
    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        // 两个引擎都设置,保证切换引擎后音量一致。
        localEngine.setVolume(volume)
        youtubeEngine.setVolume(volume)
    }
    /// EQ 在两个引擎上都设置,使其在 local / youtube 间切换后保持一致。
    func setEQ(_ bands: [EQBand]) {
        localEngine.setEQ(bands)
        youtubeEngine.setEQ(bands)
    }
    func installSpectrumHandler(_ h: @escaping (SpectrumFrame) -> Void) {
        spectrumHandler = h
        currentEngine?.installSpectrumTap(h)
    }
    func removeSpectrumHandler() {
        spectrumHandler = nil
        currentEngine?.removeSpectrumTap()
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
        // 按 youTubeId 分发:有 id 走 YouTube,否则走本地。
        let targetEngine: any PlayerEngine = track.youTubeId != nil ? youtubeEngine : localEngine

        // 引擎切换:停掉旧引擎的频谱 tap 与播放,在新引擎上重装频谱处理器。
        // `PlayerEngine` 是 `AnyObject`,用引用同一性判断当前与目标是否不同。
        if currentEngine == nil
            || (currentEngine! as AnyObject) !== (targetEngine as AnyObject) {
            currentEngine?.pause()
            currentEngine?.removeSpectrumTap()
            currentEngine = targetEngine
            if let handler = spectrumHandler {
                targetEngine.installSpectrumTap(handler)
            }
        }

        // 预设 track 以便 UI 即时反馈(计算 state 委托到 targetEngine.state)。
        state.track = track
        lastCompletedTrackId = nil
        do {
            try await targetEngine.load(track)
            targetEngine.play()
            // 预加载下一首(本地无缝播放的前置条件)
            prepareNext()
        } catch {
            // 引擎已在 load 中设置了 state.error(本地用 .decodingFailed,
            // YouTube 用 .sourceUnavailable);此处只负责停播,不覆盖错误。
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