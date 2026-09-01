import Foundation
import AVFoundation

/// `YTDlpBridge` 的抽象协议,便于在测试中注入 mock。
/// 协议方法不带默认参数(协议不允许),实现端 `YTDlpBridge` 自带默认值,可直接满足。
@MainActor
protocol YTDlpBridgeProtocol: AnyObject {
    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    func version() async -> String?
}

extension YTDlpBridge: YTDlpBridgeProtocol {}

/// YouTube 流播放引擎:`PlayerEngine` 协议实现。
///
/// 播放图使用双 `AVAudioPlayerNode` → preMixer →
/// AVAudioUnitEQ(32 bands) → mainMixerNode,支持队列下一首的无缝切换。
///
/// 三种播放路径:
/// 1. **AVAudioFile(主路径,EQ/频谱可用)**:本地临时文件已存在(上次播放或
///    预加载留下)或下载完成时,用 `AVAudioFile` 解码并调度到 player 节点。
/// 2. **混合流式(首次播放未缓存远端曲目)**:先用 `AVPlayer` 流式即时起播
///    (此期间 EQ/频谱不可用),同时在后台下载到临时文件;下载完成后用
///    ~200ms 短淡入从 AVPlayer 切换到 AVAudioFile 路径,EQ/频谱随即生效。
/// 3. **AVPlayer 降级**:下载或解码彻底失败时,常驻 AVPlayer 播放远端 URL
///    (EQ/频谱不可用,但保证出声)。`isInFallbackMode` 仅在此情形为 true。
@MainActor
final class YouTubeStreamEngine: PlayerEngine {
    let state = PlayerState()
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let preMixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 32)
    private var spectrumTap = SpectrumTap()

    /// 当前正在播放的节点。初始为 playerA。
    private var activePlayer: AVAudioPlayerNode
    /// 空闲节点,用于预加载/无缝切换。
    private var inactivePlayer: AVAudioPlayerNode { activePlayer === playerA ? playerB : playerA }

    private var currentFile: AVAudioFile?
    private var currentTrack: TrackSnapshot?
    private var fileFrames: AVAudioFramePosition = 0
    private var posTimer: Timer?
    /// 调度代次:每次 schedule 递增,过滤 stop() 触发的过期完成回调。
    private var scheduleGen = 0
    /// Async load identity. URL resolution and download can ignore cooperative
    /// cancellation, so every continuation must also prove it still belongs to
    /// the newest requested track before touching a backend or observable state.
    private var loadGeneration: UInt64 = 0
    private var currentLoadTrackId: UUID?
    /// File-seconds at the start of the currently scheduled segment.
    private var segmentStartSec: Double = 0

    // 预加载状态(为队列下一首提前解码到 AVAudioFile)
    private var prefetchedFile: AVAudioFile?
    private var prefetchedTrack: TrackSnapshot?
    private var prefetchedFrames: AVAudioFramePosition = 0

    // AVPlayer 路径(流式起播 + 降级共用)
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endTimeObserver: NSObjectProtocol?
    /// 下载/解码彻底失败,常驻 AVPlayer。`isInFallbackMode` 仅据此返回。
    private var useAVPlayerFallback = false
    /// 混合流式阶段:AVPlayer 即时起播中,等待后台下载完成后切换到 AVAudioFile。
    private var isStreamingMode = false
    /// 混合切换任务(后台下载+解码+淡入切换),可被取消。
    private var swapTask: Task<Void, Never>?
    /// Playback intent is independent from `state.isPlaying`: the latter may be
    /// false while a backend is loading or being swapped. Every backend handoff
    /// must consult this value before it is allowed to emit audio.
    private var playbackRequested = false

    private let bridge: any YTDlpBridgeProtocol
    private let cache: StreamURLCache
    private let session: URLSession
    private let downloadOverride: ((URL, URL) async -> Bool)?
    private let log = AppLog.for("YouTubeStreamEngine")
    /// 预加载任务(为队列下一首在后台下载+解码)。
    private var preloadTask: Task<Void, Never>?
    private var prefetchGeneration: UInt64 = 0

    /// 测试可见的降级状态查询:仅当下载/解码彻底失败常驻 AVPlayer 时为 true。
    /// 混合流式阶段(意图性 AVPlayer 起播)不算 fallback。
    var isInFallbackMode: Bool { useAVPlayerFallback }

    // MARK: - 测试可见的内部状态(便于双节点切换断言)

    /// 当前 active 节点是否为 playerA(双节点切换断言用)。
    var _activeIsPlayerA: Bool { activePlayer === playerA }
    /// 是否已有预加载完成的 AVAudioFile(供 `playPrepared()` 无缝切换)。
    var _isPrefetched: Bool { prefetchedFile != nil }
    /// 是否处于混合流式阶段(AVPlayer 即时起播,等待后台下载完成切换)。
    var _isStreamingMode: Bool { isStreamingMode }
    /// Regression-test seam for detecting a backend that outlives paused state.
    var _hasActivePlayback: Bool {
        playerA.isPlaying || playerB.isPlaying || (avPlayer?.rate ?? 0) > 0
    }

    var onCompletion: (@MainActor () -> Void)?

    init(bridge: any YTDlpBridgeProtocol,
         cache: StreamURLCache = .default,
         session: URLSession = .shared,
         downloadOverride: ((URL, URL) async -> Bool)? = nil) {
        self.bridge = bridge
        self.cache = cache
        self.session = session
        self.downloadOverride = downloadOverride
        activePlayer = playerA
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(preMixer)
        engine.attach(eq)
        // 双播放器 → preMixer(多输入总线)→ EQ → 主混音器
        engine.connect(playerA, to: preMixer, format: nil)
        engine.connect(playerB, to: preMixer, format: nil)
        engine.connect(preMixer, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - 运行时 IO 周期门禁

    /// 运行时 IO 周期就绪信号。
    /// 仅在为真且 `hasAudioOutput` 时调用 `player.play()`,避免 headless 进程崩溃。
    private var ioCycleReady = false

    private var hasAudioOutput: Bool {
        engine.mainMixerNode.outputFormat(forBus: 0).sampleRate > 0
    }

    /// 确保 engine 已 start 并等待渲染线程进入 IO 周期(RunLoop 自旋至
    /// `mainMixerNode.lastRenderTime` 非 nil,超时则 `ioCycleReady = false`)。
    @discardableResult
    private func ensureEngineRunning() -> Bool {
        if engine.isRunning && ioCycleReady { return true }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() }
            catch { ioCycleReady = false; return false }
        }
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while engine.mainMixerNode.lastRenderTime == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        ioCycleReady = (engine.mainMixerNode.lastRenderTime != nil)
        return ioCycleReady
    }

    // MARK: - PlayerEngine

    /// 预加载队列下一首:后台解析+下载+解码到 `AVAudioFile`,存入 prefetch 槽。
    /// 不调度、不播放,供 `playPrepared()` 无缝切换。
    /// 为保证 `playPrepared()` 可确定性命中,`prepare` 会等待预加载完成再返回
    /// (PlaybackService 已在 `Task` 中调用本方法,UI 不会阻塞)。
    func prepare(_ track: TrackSnapshot) async {
        let videoId = track.youTubeId
        guard !videoId.isEmpty else { return }
        if prefetchedTrack?.youTubeId == videoId, prefetchedFile != nil { return }
        cancelAndClearPrefetch()
        let generation = prefetchGeneration
        prefetchedTrack = track
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.preloadAndDecode(videoId: videoId, track: track,
                                        generation: generation)
        }
        preloadTask = task
        _ = await task.value
    }

    /// 无缝切换到 `prepare()` 预加载的曲目:在空闲节点调度+播放+交换,返回 true。
    /// 无预加载或预加载未完成时返回 false,由 PlaybackService 回退到 `load()`。
    @discardableResult
    func playPrepared() -> Bool {
        guard let file = prefetchedFile, let track = prefetchedTrack else { return false }
        tearDownAVPlayer()
        cancelStreamingSwap()
        isStreamingMode = false
        useAVPlayerFallback = false

        scheduleGen += 1
        let next = inactivePlayer
        next.stop()
        next.scheduleFile(file, at: nil) { }
        ensureEngineRunning()
        next.volume = currentTargetVolume()
        if ioCycleReady && hasAudioOutput { next.play() }
        activePlayer.stop()
        activePlayer = next

        currentFile = file
        currentTrack = track
        state.track = track
        fileFrames = prefetchedFrames
        applyFileState(file: file, track: track)

        prefetchedFile = nil
        prefetchedTrack = nil
        prefetchedFrames = 0
        preparedVideoId = nil
        preparedTempURL = nil

        playbackRequested = true
        state.isPlaying = true
        startPosTimer()
        return true
    }

    func load(_ track: TrackSnapshot) async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        currentLoadTrackId = track.id

        // 1. 取消进行中的下载 / 预加载 / 混合切换
        downloadTask?.cancel()
        downloadTask = nil
        cancelAndClearPrefetch()
        resetPlaybackForNewLoad()

        // 2. 校验 videoId
        let videoId = track.youTubeId
        guard !videoId.isEmpty else {
            state.error = .sourceUnavailable
            state.buffering = false
            throw PlayerError.sourceUnavailable
        }

        // 3. 进入缓冲态。所有旧后端已在 resetPlaybackForNewLoad 中静音。
        state.buffering = true
        state.track = track
        currentTrack = track
        state.error = nil

        // 5. 优先复用磁盘上的临时文件 → AVAudioFile 主路径(瞬时,EQ/频谱可用)。
        if let cachedURL = existingTempFile(for: videoId),
           decodeAndScheduleOnInactive(tempURL: cachedURL, track: track, fromFrame: 0) {
            return
        }

        // 6. 解析流 URL(缓存优先,失败重试一次)
        let resolvedURL: URL
        do {
            resolvedURL = try await resolveStreamURL(for: videoId)
        } catch {
            guard loadIsCurrent(generation: generation, trackId: track.id) else { return }
            state.error = .sourceUnavailable
            state.buffering = false
            throw PlayerError.sourceUnavailable
        }
        guard loadIsCurrent(generation: generation, trackId: track.id),
              !Task.isCancelled else { return }

        // 7a. 已解析到文件 URL：直接复制到 YouTube 流缓存后走 AVAudioFile 主路径。
        if resolvedURL.isFileURL {
            let tempURL = cacheFileURL(videoId: videoId, from: resolvedURL)
            let downloadOK = await downloadTo(url: resolvedURL, tempURL: tempURL)
            guard loadIsCurrent(generation: generation, trackId: track.id),
                  !Task.isCancelled else { return }
            if downloadOK, decodeAndScheduleOnInactive(tempURL: tempURL, track: track, fromFrame: 0) {
                return
            }
            // 文件 URL 的缓存/解码失败时，降级为 AVPlayer。
            startAVPlayer(url: resolvedURL, fallback: true,
                          loadGeneration: generation, trackId: track.id)
            return
        }

        // 7b. 远端 URL(未缓存):混合流式 — AVPlayer 即时起播,后台下载后切换。
        startAVPlayer(url: resolvedURL, fallback: false,
                      loadGeneration: generation, trackId: track.id)
        isStreamingMode = true
        state.buffering = false
        state.error = nil
        state.quality = AudioQualityInfo(
            sampleRate: 0, bitDepth: 0, codec: "native", isLossless: false)

        let tempURL = cacheFileURL(videoId: videoId, from: resolvedURL)
        let downloadTaskRef = Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.downloadTo(url: resolvedURL, tempURL: tempURL)
            guard !Task.isCancelled,
                  self.loadIsCurrent(generation: generation, trackId: track.id) else { return }
            if ok {
                self.beginStreamingSwap(to: tempURL, track: track,
                                        loadGeneration: generation)
            } else {
                // 下载失败:常驻 AVPlayer 降级
                self.isStreamingMode = false
                self.useAVPlayerFallback = true
                self.log.error("流式下载失败,常驻 AVPlayer 降级")
            }
        }
        downloadTask = downloadTaskRef
        // Return immediately so PlaybackService.play() can start AVPlayer while
        // the download continues. Awaiting here delayed first sound until the
        // entire file was on disk.
    }

    /// Test hook: wait until the hybrid download (and swap kickoff) finishes.
    func awaitHybridWorkForTests() async {
        await downloadTask?.value
        await swapTask?.value
    }

    func play() {
        playbackRequested = true
        if useAVPlayerFallback || isStreamingMode {
            avPlayer?.play()
            state.isPlaying = true
            return
        }
        ensureEngineRunning()
        if ioCycleReady && hasAudioOutput { activePlayer.play() }
        state.isPlaying = true
        startPosTimer()
    }

    func pause() {
        playbackRequested = false
        // A hybrid handoff briefly owns both backends. Pause all of them rather
        // than trusting mode flags that may change at the next suspension point.
        avPlayer?.pause()
        playerA.pause()
        playerB.pause()
        state.isPlaying = false
        posTimer?.invalidate()
    }

    func toggle() { (playbackRequested || state.isPlaying) ? pause() : play() }

    func seek(to time: Double) {
        if useAVPlayerFallback || isStreamingMode {
            avPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            state.position = time
            return
        }
        guard let file = currentFile else { return }
        let sr = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(time * sr)
        scheduleGen += 1
        activePlayer.stop()
        let remaining = fileFrames - frame
        if remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
            activePlayer.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) { }
            ensureEngineRunning()
            if state.isPlaying && ioCycleReady && hasAudioOutput { activePlayer.play() }
            state.position = time
            segmentStartSec = time
        }
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        if useAVPlayerFallback || isStreamingMode {
            avPlayer?.volume = clamped
            return
        }
        activePlayer.volume = clamped
        // 同步空闲节点,避免切换时音量跳变
        inactivePlayer.volume = clamped
    }

    func setEQ(_ bands: [EQBand]) {
        // AVPlayer 路径下 EQ 不可用
        if useAVPlayerFallback || isStreamingMode { return }
        for i in 0..<min(bands.count, eq.bands.count) {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = Float(bands[i].frequency)
            b.gain = Float(bands[i].gain)
            b.bandwidth = Float(bands[i].q)
            b.bypass = false
        }
        for i in bands.count..<eq.bands.count { eq.bands[i].bypass = true }
    }

    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {
        // AVPlayer 路径下频谱不可用,不安装 tap
        if useAVPlayerFallback || isStreamingMode { return }
        spectrumTap.start(on: eq, bus: 0,
                          format: eq.outputFormat(forBus: 0), handler: handler)
    }

    func removeSpectrumTap() { spectrumTap.stop() }

    // MARK: - 混合流式:AVPlayer → AVAudioFile 短淡入切换

    /// 开始从 AVPlayer 流式起播切换到本地 AVAudioFile:后台解码 + ~200ms 淡入。
    /// 解码在 `Task` 中进行(AVPlayer 仍在播放,不阻塞 UI —— 后台解码),
    /// 解码完成后转入 async 淡入步进。
    private func beginStreamingSwap(to tempURL: URL, track: TrackSnapshot,
                                    loadGeneration: UInt64) {
        guard loadIsCurrent(generation: loadGeneration, trackId: track.id) else { return }
        let gen = scheduleGen
        swapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 后台解码:打开 AVAudioFile(AVPlayer 仍在出声,不阻塞 UI)
            let file: AVAudioFile?
            do { file = try AVAudioFile(forReading: tempURL) }
            catch { self.log.error("流式切换解码失败:\(error.localizedDescription)"); file = nil }
            guard let file,
                  !Task.isCancelled,
                  gen == self.scheduleGen,
                  self.loadIsCurrent(generation: loadGeneration,
                                     trackId: track.id) else { return }
            // 在主线程完成淡入切换(async,每步 Task.sleep 让出 actor)
            await self.performStreamingSwap(file: file, track: track,
                                            loadGeneration: loadGeneration)
        }
    }

    /// 执行 AVPlayer → AVAudioPlayerNode 的 ~200ms 淡入切换。
    /// 从 AVPlayer 当前播放位置对应帧开始 scheduleSegment,音量交叉淡入。
    /// 以 async 形式执行淡入步进(每步 `Task.sleep`),避免 Timer 闭包跨
    /// actor 捕获带来的 Sendable/数据竞争问题。每步检查 `Task.isCancelled`
    /// 与 `scheduleGen` 代次,被 `load()`/`seek()` 取消时立即终止。
    private func performStreamingSwap(file: AVAudioFile,
                                      track: TrackSnapshot,
                                      loadGeneration: UInt64) async {
        guard loadIsCurrent(generation: loadGeneration, trackId: track.id) else { return }
        let sr = file.processingFormat.sampleRate
        let posSec = avPlayer?.currentTime().seconds ?? 0
        let startFrame = max(0, AVAudioFramePosition(posSec * sr))
        let totalFrames = file.length
        let remaining = totalFrames - startFrame
        guard remaining > 0 else {
            // 已接近末尾,直接停止 AVPlayer,不必切换
            tearDownAVPlayer()
            isStreamingMode = false
            return
        }

        scheduleGen += 1
        let myGen = scheduleGen
        let next = inactivePlayer
        next.stop()
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        next.scheduleSegment(file, startingFrame: startFrame, frameCount: count, at: nil) { }
        ensureEngineRunning()

        let targetVol = currentTargetVolume()
        next.volume = 0
        if playbackRequested, ioCycleReady, hasAudioOutput { next.play() }

        // ~200ms 淡入(10 步 × 20ms):AVPlayer 音量 →0,AVAudioPlayerNode →target
        let steps = 10
        for step in 1...steps {
            if Task.isCancelled
                || myGen != self.scheduleGen
                || !loadIsCurrent(generation: loadGeneration, trackId: track.id) {
                return
            }
            if playbackRequested {
                avPlayer?.play()
                if !next.isPlaying, ioCycleReady, hasAudioOutput { next.play() }
            } else {
                avPlayer?.pause()
                next.pause()
            }
            let progress = Float(step) / Float(steps)
            avPlayer?.volume = targetVol * (1 - progress)
            next.volume = targetVol * progress
            try? await Task.sleep(for: .milliseconds(20))
        }
        if Task.isCancelled
            || myGen != self.scheduleGen
            || !loadIsCurrent(generation: loadGeneration, trackId: track.id) {
            return
        }

        // 切换完成:拆除 AVPlayer,交换 active 节点,EQ/频谱随即生效
        tearDownAVPlayer()
        isStreamingMode = false
        useAVPlayerFallback = false
        activePlayer.stop()
        activePlayer = next
        currentFile = file
        currentTrack = track
        state.track = track
        fileFrames = totalFrames
        let pos = Double(startFrame) / sr
        applyFileState(file: file, track: track, position: pos)
        if playbackRequested {
            if !next.isPlaying, ioCycleReady, hasAudioOutput { next.play() }
            state.isPlaying = true
            startPosTimer()
        } else {
            next.pause()
            state.isPlaying = false
            posTimer?.invalidate()
        }
    }

    private func cancelStreamingSwap() {
        swapTask?.cancel()
        swapTask = nil
    }

    private func loadIsCurrent(generation: UInt64, trackId: UUID) -> Bool {
        loadGeneration == generation
            && currentLoadTrackId == trackId
            && state.track?.id == trackId
    }

    private func cancelAndClearPrefetch() {
        prefetchGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        prefetchedFile = nil
        prefetchedTrack = nil
        prefetchedFrames = 0
        preparedVideoId = nil
        preparedTempURL = nil
    }

    private func prefetchIsCurrent(generation: UInt64, trackId: UUID) -> Bool {
        prefetchGeneration == generation && prefetchedTrack?.id == trackId
    }

    /// Establish one silent, normalized backend state before loading a new
    /// source. This prevents an old decoded node from continuing underneath a
    /// new AVPlayer and makes later pause calls independent of stale mode flags.
    private func resetPlaybackForNewLoad() {
        scheduleGen += 1
        cancelStreamingSwap()
        posTimer?.invalidate()
        posTimer = nil
        playerA.stop()
        playerB.stop()
        tearDownAVPlayer()
        isStreamingMode = false
        useAVPlayerFallback = false
        playbackRequested = false
        state.isPlaying = false
        currentFile = nil
        fileFrames = 0
        segmentStartSec = 0
    }

    // MARK: - AVAudioFile 主路径

    /// 解码本地临时文件并在空闲节点调度(双节点交换)。成功返回 true。
    /// `fromFrame` 指定从文件第几帧开始(0 = 整曲;流式切换时为 AVPlayer 当前位置)。
    private func decodeAndScheduleOnInactive(tempURL: URL, track: TrackSnapshot,
                                             fromFrame: AVAudioFramePosition) -> Bool {
        do {
            let file = try AVAudioFile(forReading: tempURL)
            scheduleGen += 1
            let next = inactivePlayer
            next.stop()
            if fromFrame > 0 {
                let remaining = file.length - fromFrame
                guard remaining > 0 else { return false }
                let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
                next.scheduleSegment(file, startingFrame: fromFrame, frameCount: count, at: nil) { }
            } else {
                next.scheduleFile(file, at: nil) { }
            }
            if !ensureEngineRunning() {
                state.error = .engineStartFailed
                return false
            }
            next.volume = currentTargetVolume()
            // load() 路径下尚未 play(),不在此处 play();play() 由 PlaybackService 触发。
            activePlayer.stop()
            activePlayer = next

            currentFile = file
            currentTrack = track
            fileFrames = file.length
            let pos = fromFrame > 0
                ? Double(fromFrame) / file.processingFormat.sampleRate : 0
            applyFileState(file: file, track: track, position: pos)
            preparedTempURL = tempURL
            preparedVideoId = track.youTubeId
            return true
        } catch {
            log.error("AVAudioFile 解码失败:\(error.localizedDescription)")
            return false
        }
    }

    /// 把 AVAudioFile 的时长/质量信息写入 `state`(AVAudioFile 主路径共用)。
    private func applyFileState(file: AVAudioFile, track: TrackSnapshot,
                                position: Double = 0) {
        let sr = file.processingFormat.sampleRate
        state.duration = Double(file.length) / sr
        state.position = position
        segmentStartSec = position
        state.quality = AudioQualityInfo(
            sampleRate: Int(sr),
            bitDepth: 16,
            codec: guessCodec(from: file.url),
            isLossless: false)
        state.error = nil
        state.buffering = false
    }

    /// 当前目标音量(优先 AVPlayer 音量,否则 activePlayer 音量)。
    private func currentTargetVolume() -> Float {
        if useAVPlayerFallback || isStreamingMode {
            return avPlayer?.volume ?? 0.8
        }
        return activePlayer.volume == 0 ? 0.8 : activePlayer.volume
    }

    // MARK: - 预加载(为队列下一首后台下载+解码)

    /// 后台:解析+下载到临时文件,再打开 AVAudioFile 存入 prefetch 槽。
    private func preloadAndDecode(videoId: String, track: TrackSnapshot,
                                  generation: UInt64) async {
        guard prefetchIsCurrent(generation: generation, trackId: track.id) else { return }
        // 文件已在磁盘:直接打开
        if let cached = existingTempFile(for: videoId) {
            if let file = try? AVAudioFile(forReading: cached),
               prefetchIsCurrent(generation: generation, trackId: track.id) {
                prefetchedFile = file
                prefetchedTrack = track
                prefetchedFrames = file.length
                preparedTempURL = cached
                preparedVideoId = videoId
            }
            return
        }
        do {
            let resolvedURL = try await resolveStreamURL(for: videoId)
            guard !Task.isCancelled,
                  prefetchIsCurrent(generation: generation, trackId: track.id) else { return }
            let tempURL = cacheFileURL(videoId: videoId, from: resolvedURL)
            let ok = await downloadTo(url: resolvedURL, tempURL: tempURL)
            guard ok,
                  !Task.isCancelled,
                  prefetchIsCurrent(generation: generation, trackId: track.id) else { return }
            if let file = try? AVAudioFile(forReading: tempURL),
               prefetchIsCurrent(generation: generation, trackId: track.id) {
                prefetchedFile = file
                prefetchedTrack = track
                prefetchedFrames = file.length
                preparedTempURL = tempURL
                preparedVideoId = videoId
            }
        } catch {
            log.error("预加载失败:\(error.localizedDescription)")
        }
    }

    // MARK: - AVPlayer 路径(流式起播 + 降级共用)

    /// 启动 AVPlayer 播放 `url`。`fallback` 为 true 表示常驻降级(下载/解码失败)。
    private func startAVPlayer(url: URL, fallback: Bool,
                               loadGeneration: UInt64, trackId: UUID) {
        useAVPlayerFallback = fallback
        let item = AVPlayerItem(url: url)
        avPlayer = AVPlayer(playerItem: item)
        avPlayer?.volume = currentTargetVolume()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self,
                      self.loadIsCurrent(generation: loadGeneration, trackId: trackId),
                      let p = self.avPlayer else { return }
                self.state.position = cmTime.seconds
                if let dur = p.currentItem?.duration,
                   dur.seconds.isFinite, dur.seconds > 0 {
                    self.state.duration = dur.seconds
                }
            }
        }
        endTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.loadIsCurrent(generation: loadGeneration, trackId: trackId) else {
                    return
                }
                self.handleCompletion()
            }
        }
    }

    private func tearDownAVPlayer() {
        if let t = timeObserver { avPlayer?.removeTimeObserver(t); timeObserver = nil }
        if let o = endTimeObserver {
            NotificationCenter.default.removeObserver(o); endTimeObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        useAVPlayerFallback = false
    }

    // MARK: - 下载

    private var downloadTask: Task<Void, Never>?

    /// 下载 `url` 到 `tempURL`(本地 file URL 直接拷贝)。远端走 `download(from:)` 落盘,不把整文件读进 Data。
    private func downloadTo(url: URL, tempURL: URL) async -> Bool {
        if let downloadOverride {
            return await downloadOverride(url, tempURL)
        }
        do {
            if url.isFileURL {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                return true
            }
            let (tmp, resp) = try await session.download(from: url)
            if let http = resp as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw PlayerError.networkError("非 2xx 响应")
            }
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.moveItem(at: tmp, to: tempURL)
            return true
        } catch {
            log.error("下载失败:\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 临时文件 / URL 解析

    private func currentQuality() -> String {
        UserDefaults.standard.string(forKey: PrefKey.ytAudioQuality) ?? "bestaudio"
    }

    private func cacheFileURL(videoId: String, from url: URL) -> URL {
        MediaFileCache.file(videoId: videoId, quality: currentQuality(), ext: guessExt(from: url))
    }

    /// Cached file for this video at the current quality (> 4 KB).
    private func existingTempFile(for videoId: String) -> URL? {
        MediaFileCache.existing(videoId: videoId, quality: currentQuality())
    }

    /// 已预加载(后台下载完成)的 videoId / 文件 URL,供外部查询。
    private var preparedVideoId: String?
    private var preparedTempURL: URL?

    /// 解析流 URL:缓存优先,首次失败则失效缓存并重试一次(15s 超时)。
    private func resolveStreamURL(for videoId: String) async throws -> URL {
        let quality = currentQuality()
        if let cached = cache.get(videoId: videoId, quality: quality) {
            return cached
        }
        do {
            let url = try await bridge.resolveStreamURL(
                videoId: videoId, quality: quality, timeout: 15)
            cache.set(videoId: videoId, url: url, quality: quality)
            return url
        } catch {
            log.error("首次解析失败:\(error.localizedDescription),将重试一次")
            cache.invalidate(videoId: videoId, quality: quality)
            do {
                let url = try await bridge.resolveStreamURL(
                    videoId: videoId, quality: quality, timeout: 15)
                cache.set(videoId: videoId, url: url, quality: quality)
                return url
            } catch {
                log.error("重试仍失败:\(error.localizedDescription)")
                throw PlayerError.sourceUnavailable
            }
        }
    }

    // MARK: - 位置计时 / 完成

    private func startPosTimer() {
        posTimer?.invalidate()
        let generation = scheduleGen
        let trackId = state.track?.id
        posTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.scheduleGen,
                      self.state.track?.id == trackId,
                      let file = self.currentFile else { return }
                let sr = file.processingFormat.sampleRate
                self.state.position = PlayerPosition.seconds(
                    player: self.activePlayer,
                    segmentStart: self.segmentStartSec,
                    fileSampleRate: sr)
                if self.state.duration > 0, self.state.position >= self.state.duration {
                    self.handleCompletion()
                }
            }
        }
    }

    private func handleCompletion() {
        posTimer?.invalidate()
        playbackRequested = false
        state.isPlaying = false
        onCompletion?()
    }

    // MARK: - 工具

    private func streamsDir() -> URL { MediaFileCache.directory }

    private func guessExt(from url: URL) -> String {
        let e = url.pathExtension
        let known = ["m4a", "mp4", "webm", "ogg", "wav", "mp3", "aac", "opus"]
        if let lower = e.lowercased() as String?, known.contains(lower) {
            return lower
        }
        return "m4a"
    }

    private func guessCodec(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "aac"
        case "mp3": return "mp3"
        case "ogg", "opus": return "opus"
        case "wav": return "pcm"
        case "aac": return "aac"
        case "webm": return "opus"
        default: return "unknown"
        }
    }
}
