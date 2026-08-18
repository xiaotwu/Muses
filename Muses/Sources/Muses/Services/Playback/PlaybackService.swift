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
    /// 资料库服务:用于记录播放历史(`recordPlay`)。测试可不传(nil 时跳过记录)。
    weak var library: LibraryService?
    /// 跨特性播放事件总线(Phase 16 起:History/Session/Context/Inbox/Focus 订阅)。
    /// 由 PlaybackService 持有单例;外部经 `eventBus.subscribe` 注册。
    let eventBus = PlaybackEventBus()
    private(set) var volume: Float = 0.8
    private var completionObserver: Task<Void, Never>?
    private var lastCompletedTrackId: UUID?
    /// Phase 18 会话恢复:load 后要 seek 到的毫秒位(由 `resumeCurrent(atMs:)` 设置,
    /// 在 `load(_:)` 末尾一次性消费)。nil = 从 0 开始(正常播放路径)。
    private var pendingResumeMs: Double?

    init(localEngine: any PlayerEngine, youtubeEngine: any PlayerEngine,
         queue: QueueService, library: LibraryService? = nil) {
        self.localEngine = localEngine
        self.youtubeEngine = youtubeEngine
        self.queue = queue
        self.library = library
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

        // 自然完成:发出 .trackCompleted(供 HistoryService 记录 completed)。
        // 不走 next() 的位移路径,避免把自然完成误判为 skip/stop。
        postCompletedForCurrent()

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
            // 无预加载(YouTube 或无下一首):回退到不记位移的推进
            advanceWithoutDisplacement()
        }
    }

    /// 自然完成路径专用的推进:不发出 skip/stop 位移事件(完成事件已发出)。
    /// 与用户主动 next() 共享队列推进逻辑,但绕过位移记录。
    private func advanceWithoutDisplacement() {
        guard let item = queue.next() else {
            // .all 边界: 第一次返回 nil, 再调一次即可回到首项
            if queue.repeatMode == .all {
                if let item2 = queue.next() {
                    Task { await load(item2.track) }
                } else {
                    state.isPlaying = false
                }
            } else {
                state.isPlaying = false
            }
            return
        }
        Task { await load(item.track) }
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
        // 直接选曲:若当前有曲目在播,先记位移(用户切换走了旧曲目)。
        postDisplacementForCurrent()
        queue.play(track, context: context, from: from)
        Task { await loadCurrent() }
    }

    func toggle() {
        let wasPlaying = state.isPlaying
        currentEngine?.toggle()
        guard let track = state.track else { return }
        if wasPlaying {
            eventBus.post(.trackPaused(track))
        } else {
            eventBus.post(.trackResumed(track))
        }
    }
    func pause() {
        currentEngine?.pause()
        if let track = state.track { eventBus.post(.trackPaused(track)) }
    }
    func seek(to time: Double) {
        currentEngine?.seek(to: time)
        if let track = state.track {
            eventBus.post(.trackSeeked(trackId: track.id, toMs: time * 1000.0))
        }
    }
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
        // 用户主动切下一首:先记当前曲目的位移(skip/stop)。
        postDisplacementForCurrent()
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
        // 用户主动切上一首:先记当前曲目的位移。
        postDisplacementForCurrent()
        guard let item = queue.previous() else { return }
        // 若返回的就是当前正在播放的曲目(已在首位/历史空), 跳过 reload 避免抖动
        if item.track.id == state.track?.id { return }
        Task { await load(item.track) }
    }

    private func loadCurrent() async {
        guard let item = queue.current() else { return }
        await load(item.track)
    }

    /// Phase 18 会话恢复:加载队列当前曲目并 seek 到 `atMs`(毫秒)。
    /// 由 `SessionService.continuePendingSession` 在用户选择「继续上次会话」时调用。
    /// 实际 seek 在 `load(_:)` 末尾按 `pendingResumeMs` 消费(并 clamp 到 duration-2s,
    /// 对应 Final Spec §10.5 的 `min(currentPositionMs, duration-2s)`)。
    func resumeCurrent(atMs ms: Double?) {
        pendingResumeMs = ms
        Task { await loadCurrent() }
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
            // 通知订阅者播放源在 local / youtube 间切换。
            eventBus.post(.playbackSourceChanged(source: track.youTubeId != nil ? .youtube : .local))
        }

        // 预设 track 以便 UI 即时反馈(计算 state 委托到 targetEngine.state)。
        state.track = track
        lastCompletedTrackId = nil
        do {
            try await targetEngine.load(track)
            targetEngine.play()
            // 记录播放历史(本地 + YouTube):曲目已开始播放。
            library?.recordPlay(trackId: track.id)
            // 通知订阅者:新曲目已开始(Phase 17 History/Session 据此记录 ListeningEvent)。
            eventBus.post(.trackStarted(track))
            // 预加载下一首(本地无缝播放的前置条件)
            prepareNext()
            // Phase 18 会话恢复:若 `resumeCurrent(atMs:)` 预置了恢复位,在此消费。
            // clamp 到 duration-2s(末尾留 2s 余量,避免落到完成检测阈值触发误推进)。
            if let resumeMs = pendingResumeMs {
                pendingResumeMs = nil
                let targetSec = resumeMs / 1000.0
                let clamped = state.duration > 0
                    ? min(targetSec, max(0, state.duration - 2.0))
                    : targetSec
                if clamped > 0 { seek(to: clamped) }
            }
        } catch {
            // 引擎已在 load 中设置了 state.error(本地用 .decodingFailed,
            // YouTube 用 .sourceUnavailable);此处只负责停播,不覆盖错误。
            state.isPlaying = false
        }
    }

    /// 用户主动切歌(下一首/上一首/直接选曲)时,为当前曲目发出位移事件。
    /// 按收听时长判定:`< min(30s, 20% 时长)` → `.trackSkipped`,否则 `.trackStopped`
    /// (充分收听但非自然结束)。时长未知时阈值退化为 30s。仅发出事件,不改变播放行为。
    private func postDisplacementForCurrent() {
        guard let track = state.track else { return }
        let listenedMs = max(0, state.position) * 1000.0
        let durMs = track.durationSeconds * 1000.0
        let threshold = durMs > 0 ? min(30_000.0, 0.2 * durMs) : 30_000.0
        if listenedMs < threshold {
            eventBus.post(.trackSkipped(track, listenedMs: listenedMs))
        } else {
            eventBus.post(.trackStopped(track, listenedMs: listenedMs))
        }
    }

    /// 自然完成(引擎完成回调 / 轮询发现 position 抵达 duration):发出 `.trackCompleted`,
    /// listenedMs 记为整曲时长。时长未知时记 0。
    private func postCompletedForCurrent() {
        guard let track = state.track else { return }
        let listenedMs = track.durationSeconds * 1000.0
        eventBus.post(.trackCompleted(track, listenedMs: max(0, listenedMs)))
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
                    // 同一曲物的完成只推进一次, 避免轮询重复触发
                    if self.lastCompletedTrackId == self.state.track?.id { continue }
                    self.lastCompletedTrackId = self.state.track?.id
                    // 自然完成:发出 .trackCompleted;用不记位移的推进,避免误判为 skip/stop。
                    self.postCompletedForCurrent()
                    // 队列耗尽(.off 且在最后一首且无插队)则停止
                    if self.queue.repeatMode == .off,
                       self.queue.currentIndex >= self.queue.items.count - 1,
                       self.queue.upNext.isEmpty {
                        self.state.isPlaying = false
                    } else {
                        self.advanceWithoutDisplacement()
                    }
                }
            }
        }
    }
}