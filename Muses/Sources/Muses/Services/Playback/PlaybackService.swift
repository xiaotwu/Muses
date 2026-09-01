import Foundation

@Observable
@MainActor
final class PlaybackService {
    /// The single production playback backend is YouTubeStreamEngine.
    var state: PlayerState { engine.state }
    private let engine: any PlayerEngine
    private var spectrumHandler: ((SpectrumFrame) -> Void)?
    let queue: QueueService
    /// 资料库服务:用于记录播放历史(`recordPlay`)。测试可不传(nil 时跳过记录)。
    weak var library: LibraryService?
    /// 跨特性播放事件总线(Phase 16 起:History/Session/Context/Inbox/Focus 订阅)。
    /// 由 PlaybackService 持有单例;外部经 `eventBus.subscribe` 注册。
    let eventBus = PlaybackEventBus()
    private(set) var volume: Float
    private var completionObserver: Task<Void, Never>?
    private var lastCompletedTrackId: UUID?
    /// Canonical user intent. Engine state can temporarily be false while an
    /// asynchronous load is buffering, so it cannot by itself decide whether a
    /// late load is still allowed to start playback.
    private var playbackRequested = false
    /// Prevents a pause that wins an initial load race from producing a resume
    /// event before the track has ever actually started.
    private var startedTrackId: UUID?
    /// Incremented synchronously when a user-facing load is requested. Assigning
    /// the identity before spawning its Task prevents scheduler reordering from
    /// letting an older resume/reload request become the newest load.
    private var loadSeq: UInt64 = 0
    private struct PlaybackIdentity: Equatable {
        let loadSeq: UInt64
        let trackId: UUID
        let engineId: ObjectIdentifier
    }
    /// Last successfully loaded backend identity. Completion is only eligible
    /// while this exact identity still owns the current queue item.
    private var activePlaybackIdentity: PlaybackIdentity?
    private var completionEligibleIdentity: PlaybackIdentity?
    /// Explicit native-audio suspension used while the independent YouTube
    /// video WebView owns sound. Desired play intent remains independently
    /// mutable while one or more suspension tokens are active.
    private var nativePlaybackSuspensions: Set<UUID> = []

    private var nativePlaybackAllowed: Bool {
        playbackRequested && nativePlaybackSuspensions.isEmpty
    }

    init(engine: any PlayerEngine, queue: QueueService,
         library: LibraryService? = nil) {
        self.engine = engine
        self.queue = queue
        self.library = library
        let stored = UserDefaults.standard.object(forKey: PrefKey.volume) as? Double
            ?? Double(UserDefaults.standard.object(forKey: PrefKey.volume) as? Float ?? 0.8)
        self.volume = max(0, min(1, Float(stored)))
        engine.setVolume(volume)
        setupCompletionHandlers()
        observeCompletion()
    }

    convenience init(youtubeEngine: any PlayerEngine,
                     queue: QueueService,
                     library: LibraryService? = nil) {
        self.init(engine: youtubeEngine, queue: queue, library: library)
    }

    /// Completion callbacks: current track finished → advance the queue.
    private func setupCompletionHandlers() {
        // A callback becomes eligible only after a concrete load succeeds.
        // `registerLoadedPlayback` replaces it with a closure that captures that
        // load's immutable identity.
        engine.onCompletion = nil
    }

    /// 引擎完成回调:优先尝试无缝切换(playPrepared),失败则回退到 load。
    private func handleEngineCompletion(expected identity: PlaybackIdentity) {
        guard completionIsEligible(expected: identity) else { return }
        // Completion is one-shot for this playback identity. Any subsequent
        // callback from a superseded node/item is ignored.
        completionEligibleIdentity = nil
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
            playbackRequested = false
            state.isPlaying = false
            return
        }

        // 尝试无缝切换
        if engine.playPrepared() {
            // 无缝成功:推进队列到新当前曲目,并走与 load() 相同的起步事件。
            _ = queue.next()
            lastCompletedTrackId = nil
            if let started = queue.current()?.track ?? state.track {
                registerPreparedPlayback(started)
                markStarted(started)
            } else {
                prepareNext()
            }
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
                    playbackRequested = true
                    scheduleLoad(item2.track)
                } else {
                    playbackRequested = false
                    completionEligibleIdentity = nil
                    state.isPlaying = false
                }
            } else {
                playbackRequested = false
                completionEligibleIdentity = nil
                state.isPlaying = false
            }
            return
        }
        playbackRequested = true
        scheduleLoad(item.track)
    }

    /// 预加载队列中的下一首到当前引擎(本地曲目的无缝前置条件)。
    private func prepareNext() {
        guard let nextItem = queue.peekNext(),
              let currentTrackId = state.track?.id else { return }
        let seq = loadSeq
        let engineId = ObjectIdentifier(engine)
        Task {
            guard seq == loadSeq,
                  state.track?.id == currentTrackId,
                  ObjectIdentifier(engine) == engineId else { return }
            await engine.prepare(nextItem.track)
        }
    }

    /// Re-load the current track (used when the user changes yt-dlp quality).
    func reloadCurrent() {
        guard let track = state.track else { return }
        scheduleLoad(track)
    }

    func playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        // 直接选曲:若当前有曲目在播,先记位移(用户切换走了旧曲目)。
        postDisplacementForCurrent()
        playbackRequested = true
        // Explicitly selecting even the current track starts a new listening
        // lifecycle instead of being reported as a resume of the old one.
        startedTrackId = nil
        queue.play(track, context: context, from: from)
        scheduleLoad(track)
    }

    func toggle() {
        if playbackRequested || state.isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Idempotent play entry point for system commands and overlay restoration.
    /// During buffering this records intent only; `load(_:)` applies the latest
    /// intent after its await instead of overriding a newer pause.
    func play() {
        let wasRequested = playbackRequested
        playbackRequested = true
        guard let track = state.track else { return }
        guard nativePlaybackSuspensions.isEmpty else { return }
        guard !state.buffering else { return }
        guard !state.isPlaying else { return }
        engine.play()
        restoreCompletionEligibility(for: track)
        if startedTrackId == track.id {
            if !wasRequested { eventBus.post(.trackResumed(track)) }
        } else {
            markStarted(track)
        }
    }

    func pause() {
        let wasActive = playbackRequested || state.isPlaying
        playbackRequested = false
        completionEligibleIdentity = nil
        engine.pause()
        state.isPlaying = false
        if wasActive, let track = state.track, startedTrackId == track.id {
            eventBus.post(.trackPaused(track))
        }
    }

    /// Silence native audio without discarding desired play intent. The video
    /// overlay uses a token so nested/replaced overlays cannot resume audio
    /// while another video surface still owns sound.
    @discardableResult
    func beginNativePlaybackSuspension() -> UUID {
        let token = UUID()
        let wasAlreadySuspended = !nativePlaybackSuspensions.isEmpty
        nativePlaybackSuspensions.insert(token)
        guard !wasAlreadySuspended else { return token }

        let wasAudible = state.isPlaying
        completionEligibleIdentity = nil
        engine.pause()
        state.isPlaying = false
        if wasAudible, let track = state.track, startedTrackId == track.id {
            eventBus.post(.trackPaused(track))
        }
        return token
    }

    /// Release one video-audio suspension. `resume == false` converts the
    /// retained desired intent into an explicit pause (the existing preference
    /// semantics); otherwise the latest track/intent resumes idempotently.
    func endNativePlaybackSuspension(_ token: UUID, resume: Bool) {
        guard nativePlaybackSuspensions.remove(token) != nil else { return }
        guard nativePlaybackSuspensions.isEmpty else { return }
        guard resume else {
            playbackRequested = false
            completionEligibleIdentity = nil
            engine.pause()
            state.isPlaying = false
            return
        }
        guard playbackRequested else { return }
        guard let track = state.track, !state.buffering else { return }
        guard !state.isPlaying else { return }
        engine.play()
        restoreCompletionEligibility(for: track)
        if startedTrackId == track.id {
            eventBus.post(.trackResumed(track))
        } else {
            markStarted(track)
        }
    }
    func seek(to time: Double) {
        engine.seek(to: time)
        if let track = state.track {
            eventBus.post(.trackSeeked(trackId: track.id, toMs: time * 1000.0))
        }
    }
    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        UserDefaults.standard.set(Double(volume), forKey: PrefKey.volume)
        engine.setVolume(volume)
    }
    func setEQ(_ bands: [EQBand]) {
        engine.setEQ(bands)
    }
    func installSpectrumHandler(_ h: @escaping (SpectrumFrame) -> Void) {
        spectrumHandler = h
        engine.installSpectrumTap(h)
    }
    func removeSpectrumHandler() {
        spectrumHandler = nil
        engine.removeSpectrumTap()
    }

    func next() {
        // 用户主动切下一首:先记当前曲目的位移(skip/stop)。
        // 位移启发式同时决定 queue history 标签:听不足阈值 → .skipped,否则 .played。
        let isSkip = currentDisplacementIsSkip()
        postDisplacementForCurrent(isSkip: isSkip)
        let historyTag: QueueHistoryState = isSkip ? .skipped : .played
        guard let item = queue.next(as: historyTag) else {
            // .all 边界: 第一次返回 nil, 再调一次即可回到首项
            if queue.repeatMode == .all {
                if let item2 = queue.next(as: historyTag) {
                    playbackRequested = true
                    scheduleLoad(item2.track)
                } else {
                    playbackRequested = false
                    completionEligibleIdentity = nil
                    state.isPlaying = false
                }
            } else {
                // .off 到尾或队列为空: 停止
                playbackRequested = false
                completionEligibleIdentity = nil
                state.isPlaying = false
            }
            return
        }
        playbackRequested = true
        scheduleLoad(item.track)
    }

    func previous() {
        // 用户主动切上一首:先记当前曲目的位移。
        postDisplacementForCurrent()
        guard let item = queue.previous() else { return }
        // 若返回的就是当前正在播放的曲目(已在首位/历史空), 跳过 reload 避免抖动
        if item.track.id == state.track?.id { return }
        playbackRequested = true
        scheduleLoad(item.track)
    }

    /// Explicitly load and play the current queue item from a persisted offset.
    /// The offset belongs only to this load request and is clamped to two
    /// seconds before the known duration.
    func resumeCurrent(atMs ms: Double?) {
        guard let track = queue.current()?.track else { return }
        playbackRequested = true
        scheduleLoad(track, resumeMs: ms)
    }

    /// Restore the persisted queue item and seek position without producing
    /// audio or a new listening-history event. A later explicit Play resumes
    /// through the normal playback lifecycle.
    func restoreCurrentPaused(atMs ms: Double?) {
        guard let track = queue.current()?.track else { return }
        playbackRequested = false
        completionEligibleIdentity = nil
        scheduleLoad(track, resumeMs: ms)
    }

    private func scheduleLoad(_ track: TrackSnapshot, resumeMs: Double? = nil) {
        loadSeq &+= 1
        let seq = loadSeq
        completionEligibleIdentity = nil
        Task { await load(track, seq: seq, resumeMs: resumeMs) }
    }

    private func load(_ track: TrackSnapshot, seq: UInt64,
                      resumeMs: Double?) async {
        guard loadRequestIsCurrent(seq: seq, trackId: track.id) else { return }
        if state.track?.id != track.id {
            startedTrackId = nil
        }
        guard !track.youTubeId.isEmpty else {
            playbackRequested = false
            state.error = .sourceUnavailable
            return
        }
        guard loadRequestIsCurrent(seq: seq, trackId: track.id),
              !Task.isCancelled else { return }
        state.track = track
        state.position = 0
        state.duration = 0
        do {
            try await engine.load(track)
            guard loadRequestIsCurrent(seq: seq, trackId: track.id),
                  !Task.isCancelled else { return }
            registerLoadedPlayback(track, engine: engine, seq: seq)
            applyPlaybackIntent(to: engine)
            guard loadRequestIsCurrent(seq: seq, trackId: track.id),
                  !Task.isCancelled else { return }
            lastCompletedTrackId = nil
            if nativePlaybackAllowed { markStarted(track) }
            consumeResume(resumeMs, for: track, seq: seq)
        } catch {
            guard loadRequestIsCurrent(seq: seq, trackId: track.id) else { return }
            playbackRequested = false
            completionEligibleIdentity = nil
            state.isPlaying = false
        }
    }

    private func applyPlaybackIntent(to engine: any PlayerEngine) {
        if nativePlaybackAllowed {
            engine.play()
            completionEligibleIdentity = activePlaybackIdentity
        } else {
            engine.pause()
            completionEligibleIdentity = nil
            state.isPlaying = false
        }
    }

    private func loadRequestIsCurrent(seq: UInt64, trackId: UUID) -> Bool {
        seq == loadSeq && queue.current()?.track.id == trackId
    }

    private func playbackIdentity(for track: TrackSnapshot,
                                  engine: any PlayerEngine,
                                  seq: UInt64) -> PlaybackIdentity {
        PlaybackIdentity(loadSeq: seq, trackId: track.id,
                         engineId: ObjectIdentifier(engine))
    }

    private func registerLoadedPlayback(_ track: TrackSnapshot,
                                        engine: any PlayerEngine,
                                        seq: UInt64) {
        let identity = playbackIdentity(for: track, engine: engine, seq: seq)
        activePlaybackIdentity = identity
        installCompletionHandler(on: engine, identity: identity)
    }

    private func registerPreparedPlayback(_ track: TrackSnapshot) {
        loadSeq &+= 1
        let identity = playbackIdentity(for: track, engine: engine, seq: loadSeq)
        activePlaybackIdentity = identity
        completionEligibleIdentity = nativePlaybackAllowed ? identity : nil
        installCompletionHandler(on: engine, identity: identity)
    }

    private func installCompletionHandler(on engine: any PlayerEngine,
                                          identity: PlaybackIdentity) {
        engine.onCompletion = { [weak self] in
            self?.handleEngineCompletion(expected: identity)
        }
    }

    private func restoreCompletionEligibility(for track: TrackSnapshot) {
        guard let activePlaybackIdentity,
              activePlaybackIdentity.loadSeq == loadSeq,
              activePlaybackIdentity.trackId == track.id,
              activePlaybackIdentity.engineId == ObjectIdentifier(engine),
              queue.current()?.track.id == track.id else {
            completionEligibleIdentity = nil
            return
        }
        completionEligibleIdentity = activePlaybackIdentity
    }

    private func completionIsEligible(expected identity: PlaybackIdentity) -> Bool {
        guard nativePlaybackAllowed,
              !state.isPlaying,
              !state.buffering,
              let track = state.track,
              queue.current()?.track.id == track.id,
              let activePlaybackIdentity,
              let completionEligibleIdentity,
              identity == completionEligibleIdentity,
              activePlaybackIdentity == completionEligibleIdentity,
              activePlaybackIdentity.loadSeq == loadSeq,
              activePlaybackIdentity.trackId == track.id,
              activePlaybackIdentity.engineId == ObjectIdentifier(engine) else {
            return false
        }
        return true
    }

    private func consumeResume(_ resumeMs: Double?, for track: TrackSnapshot,
                               seq: UInt64) {
        guard loadRequestIsCurrent(seq: seq, trackId: track.id),
              let resumeMs else { return }
        let targetSec = resumeMs / 1000.0
        // A test double or a temporarily unavailable stream may not have
        // reported engine duration yet. The immutable track snapshot is a
        // valid fallback and prevents restoring beyond the known ending.
        let duration = state.duration > 0
            ? state.duration
            : (state.track?.durationSeconds ?? 0)
        let clamped = duration > 0
            ? min(targetSec, max(0, duration - 2.0))
            : targetSec
        if clamped > 0 { seek(to: clamped) }
    }

    /// Shared start-of-track side effects for `load` and gapless `playPrepared`.
    private func didStart(_ track: TrackSnapshot) {
        library?.recordPlay(trackId: track.id)
        eventBus.post(.trackStarted(track))
        prepareNext()
    }

    private func markStarted(_ track: TrackSnapshot) {
        guard startedTrackId != track.id else { return }
        startedTrackId = track.id
        didStart(track)
    }

    /// 用户主动切歌(下一首/上一首/直接选曲)时,为当前曲目发出位移事件。
    /// 按收听时长判定:`< min(30s, 20% 时长)` → `.trackSkipped`,否则 `.trackStopped`
    /// (充分收听但非自然结束)。时长未知时阈值退化为 30s。仅发出事件,不改变播放行为。
    /// `isSkip` 传入时直接采用(避免重复计算);nil 时内部计算。
    private func currentDisplacementIsSkip() -> Bool {
        guard state.track != nil else { return false }
        let listenedMs = max(0, state.position) * 1000.0
        let durMs = (state.track?.durationSeconds ?? 0) * 1000.0
        let threshold = durMs > 0 ? min(30_000.0, 0.2 * durMs) : 30_000.0
        return listenedMs < threshold
    }

    private func postDisplacementForCurrent(isSkip: Bool? = nil) {
        guard let track = state.track else { return }
        let skip = isSkip ?? currentDisplacementIsSkip()
        let listenedMs = max(0, state.position) * 1000.0
        if skip {
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
                guard !self.state.buffering else { continue }
                // A user pause near the final frame is not a natural completion.
                // Engine completion keeps the service-level intent true until
                // this method advances or exhausts the queue.
                guard self.playbackRequested else { continue }
                guard let identity = self.completionEligibleIdentity,
                      self.completionIsEligible(expected: identity) else { continue }
                // 已播完(position 抵达 duration)且引擎已停
                if self.state.position >= self.state.duration - 0.05 {
                    self.completionEligibleIdentity = nil
                    // 同一曲物的完成只推进一次, 避免轮询重复触发
                    if self.lastCompletedTrackId == self.state.track?.id { continue }
                    self.lastCompletedTrackId = self.state.track?.id
                    // 自然完成:发出 .trackCompleted;用不记位移的推进,避免误判为 skip/stop。
                    self.postCompletedForCurrent()
                    // 队列耗尽(.off 且在最后一首且无插队)则停止
                    if self.queue.repeatMode == .off,
                       self.queue.currentIndex >= self.queue.items.count - 1,
                       self.queue.upNext.isEmpty {
                        self.playbackRequested = false
                        self.completionEligibleIdentity = nil
                        self.state.isPlaying = false
                    } else {
                        self.advanceWithoutDisplacement()
                    }
                }
            }
        }
    }
}
