import Foundation
import AVFoundation

/// Abstraction over `YTDlpBridge` so tests can inject mocks.
/// Protocol methods carry no default parameters (a protocol cannot); the concrete `YTDlpBridge` provides defaults and satisfies it directly.
@MainActor
protocol YTDlpBridgeProtocol: AnyObject {
    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry]
    func version() async -> String?
    func invalidateSearch(query: String, limit: Int)
}

extension YTDlpBridgeProtocol {
    func invalidateSearch(query: String, limit: Int) {}
}

extension YTDlpBridge: YTDlpBridgeProtocol {}

/// YouTube streaming playback engine implementing the `PlayerEngine` protocol.
///
/// The playback graph uses two `AVAudioPlayerNode`s → preMixer →
/// AVAudioUnitEQ (32-band unit; the UI configures 10 bands) → mainMixerNode,
/// supporting gapless hand-off to the next queued track.
/// `setEQ` and spectrum taps are no-ops while audio is on the AVPlayer streaming path.
///
/// Three playback paths:
/// 1. **AVAudioFile (primary; EQ/spectrum available)**: the local temp file already exists (left over from a previous play or
///    a prefetch) or the download finished — decode via `AVAudioFile` and schedule onto the player node.
/// 2. Hybrid streaming (first play of an uncached remote track): start instantly with `AVPlayer`
///    (EQ/spectrum unavailable meanwhile) while downloading to a temp file in the background; once the download finishes,
///    cross over from AVPlayer to the AVAudioFile path with a ~200ms fade — EQ/spectrum become live.
/// 3. AVPlayer fallback: if download/decode fails outright, keep playing the remote URL through AVPlayer
///    (EQ/spectrum unavailable, but audio still plays). `isInFallbackMode` is true only in this case.
@MainActor
final class YouTubeStreamEngine: PlayerEngine {
    let state = PlayerState()
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let preMixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 32)
    private let timePitch = AVAudioUnitTimePitch()
    private var spectrumTap = SpectrumTap()

    /// The currently playing node. Initially playerA.
    private var activePlayer: AVAudioPlayerNode
    /// Idle node used for prefetching/gapless hand-off.
    private var inactivePlayer: AVAudioPlayerNode { activePlayer === playerA ? playerB : playerA }

    private var requestedEQ: [EQBand] = []
    private var requestedPlaybackRate: Float = 1
    private var requestedSpectrum: ((SpectrumFrame) -> Void)?
    private var currentFile: AVAudioFile? { didSet { updateAudioProcessingAvailability() } }
    private var currentTrack: TrackSnapshot?
    private var fileFrames: AVAudioFramePosition = 0
    private var posTimer: Timer?
    /// Schedule generation: incremented on every schedule to filter stale completion callbacks triggered by stop().
    private var scheduleGen = 0
    /// Async load identity. URL resolution and download can ignore cooperative
    /// cancellation, so every continuation must also prove it still belongs to
    /// the newest requested track before touching a backend or observable state.
    private var loadGeneration: UInt64 = 0
    private var currentLoadTrackId: UUID?
    /// File-seconds at the start of the currently scheduled segment.
    private var segmentStartSec: Double = 0

    // Prefetch state (decodes the next queued track to AVAudioFile ahead of time)
    private var prefetchedFile: AVAudioFile?
    private var prefetchedTrack: TrackSnapshot?
    private var prefetchedFrames: AVAudioFramePosition = 0

    // AVPlayer path (shared by streaming start and fallback)
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endTimeObserver: NSObjectProtocol?
    /// Set when download/decode failed irrecoverably and playback stays on AVPlayer. `isInFallbackMode` reports this only.
    private var useAVPlayerFallback = false { didSet { updateAudioProcessingAvailability() } }
    /// Hybrid streaming stage: AVPlayer started instantly, awaiting the background download before switching to AVAudioFile.
    private var isStreamingMode = false { didSet { updateAudioProcessingAvailability() } }
    /// Hybrid hand-off task (background download + decode + fade switch), cancellable.
    private var swapTask: Task<Void, Never>?
    /// Playback intent is independent from `state.isPlaying`: the latter may be
    /// false while a backend is loading or being swapped. Every backend handoff
    /// must consult this value before it is allowed to emit audio.
    private var playbackRequested = false
    /// User volume is authoritative across streaming, decoded playback, and
    /// preloaded hand-offs. Zero is a valid setting, never an uninitialized value.
    private var desiredVolume: Float = 0.8
    private var streamingSwapProgress: Float?

    private let bridge: any YTDlpBridgeProtocol
    private let cache: StreamURLCache
    private let session: URLSession
    private let downloadOverride: ((URL, URL) async -> Bool)?
    private let log = AppLog.for("YouTubeStreamEngine")
    /// Prefetch task (background download + decode for the next queued track).
    private var preloadTask: Task<Void, Never>?
    private var prefetchGeneration: UInt64 = 0

    /// Test-visible fallback query: true only when download/decode failed irrecoverably and AVPlayer is permanent.
    /// The hybrid streaming stage (intentional AVPlayer start) does not count as fallback.
    var isInFallbackMode: Bool { useAVPlayerFallback }

    // MARK: - Test-visible internal state (for dual-node hand-off assertions)

    /// Whether the active node is playerA (for dual-node hand-off assertions).
    var _activeIsPlayerA: Bool { activePlayer === playerA }
    /// Whether a prefetched AVAudioFile is ready for the `playPrepared()` gapless hand-off.
    var _isPrefetched: Bool { prefetchedFile != nil }
    /// Whether hybrid streaming is in progress (AVPlayer playing instantly, awaiting the background download before switching).
    var _isStreamingMode: Bool { isStreamingMode }
    var _appliedEQGains: [Float] { eq.bands.map(\.gain) }
    /// Regression-test seam for detecting a backend that outlives paused state.
    var _hasActivePlayback: Bool {
        playerA.isPlaying || playerB.isPlaying || (avPlayer?.rate ?? 0) > 0
    }
    var _backendVolumes: (active: Float, inactive: Float, stream: Float?) {
        (activePlayer.volume, inactivePlayer.volume, avPlayer?.volume)
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
        engine.attach(timePitch)
        // Two players → preMixer (multi-input bus) → EQ → main mixer
        engine.connect(playerA, to: preMixer, format: nil)
        engine.connect(playerB, to: preMixer, format: nil)
        engine.connect(preMixer, to: eq, format: nil)
        engine.connect(eq, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - Runtime IO-cycle gating

    /// Readiness signal for the runtime IO cycle.
    /// `player.play()` is called only when this is true and `hasAudioOutput`, preventing crashes in headless processes.
    private var ioCycleReady = false

    private var hasAudioOutput: Bool {
        engine.mainMixerNode.outputFormat(forBus: 0).sampleRate > 0
    }

    /// Ensures the engine is started and waits for the render thread to enter an IO cycle (spinning the run loop until
    /// `mainMixerNode.lastRenderTime` is non-nil; on timeout `ioCycleReady` becomes false).
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

    /// Prefetches the next queued track: resolves + downloads + decodes to an `AVAudioFile` in the background and stores it in the prefetch slot.
    /// Nothing is scheduled or played; `playPrepared()` uses it for the gapless hand-off.
    /// So `playPrepared()` can hit deterministically, `prepare` waits for the prefetch to finish before returning
    /// (PlaybackService already calls this inside a `Task`, so the UI is never blocked).
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

    /// Gapless hand-off to the track prefetched by `prepare()`: schedules + plays on the idle node and swaps. Returns true.
    /// Returns false with no prefetch or an unfinished one; PlaybackService then falls back to `load()`.
    @discardableResult
    func playPrepared(expectedTrackID: UUID) -> Bool {
        guard let file = prefetchedFile,
              let track = prefetchedTrack,
              track.id == expectedTrackID else { return false }
        tearDownAVPlayer()
        cancelStreamingSwap()
        isStreamingMode = false
        useAVPlayerFallback = false

        scheduleGen += 1
        let next = inactivePlayer
        next.stop()
        next.scheduleFile(file, at: nil) { }
        ensureEngineRunning()
        next.volume = desiredVolume
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

        // 1. Cancel any in-flight download / prefetch / hybrid hand-off
        downloadTask?.cancel()
        downloadTask = nil
        cancelAndClearPrefetch()
        resetPlaybackForNewLoad()

        // 2. Validate the videoId
        let videoId = track.youTubeId
        guard !videoId.isEmpty else {
            state.error = .sourceUnavailable
            state.buffering = false
            throw PlayerError.sourceUnavailable
        }

        // 3. Enter the buffering state. All old backends were muted in resetPlaybackForNewLoad.
        state.buffering = true
        state.track = track
        currentTrack = track
        state.error = nil

        // 5. Reuse an existing temp file on disk first → AVAudioFile primary path (instant; EQ/spectrum available).
        if let cachedURL = existingTempFile(for: videoId),
           decodeAndScheduleOnInactive(tempURL: cachedURL, track: track, fromFrame: 0) {
            return
        }

        // 6. Resolve the stream URL (cache first, one retry on failure)
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

        // 7a. Resolved to a file URL: copy it into the YouTube stream cache and take the AVAudioFile primary path.
        if resolvedURL.isFileURL {
            let tempURL = cacheFileURL(videoId: videoId, from: resolvedURL)
            let downloadOK = await downloadTo(url: resolvedURL, tempURL: tempURL)
            guard loadIsCurrent(generation: generation, trackId: track.id),
                  !Task.isCancelled else { return }
            if downloadOK, decodeAndScheduleOnInactive(tempURL: tempURL, track: track, fromFrame: 0) {
                return
            }
            // Fall back to AVPlayer when caching/decoding the file URL fails.
            startAVPlayer(url: resolvedURL, fallback: true,
                          loadGeneration: generation, trackId: track.id)
            return
        }

        // 7b. Remote URL (uncached): hybrid streaming — start instantly with AVPlayer, switch after the background download.
        startAVPlayer(url: resolvedURL, fallback: false,
                      loadGeneration: generation, trackId: track.id)
        isStreamingMode = true
        state.buffering = false
        state.error = nil
        state.quality = AudioQualityInfo(
            sampleRate: 0, bitDepth: 0, codec: "native", isLossless: false)

        let downloadTaskRef = Task { @MainActor [weak self] in
            guard let self else { return }
            let tempURL = await self.downloadWithRefresh(videoId: videoId, initialURL: resolvedURL)
            guard !Task.isCancelled,
                  self.loadIsCurrent(generation: generation, trackId: track.id) else { return }
            if let tempURL {
                self.beginStreamingSwap(to: tempURL, track: track,
                                        loadGeneration: generation)
            } else {
                // Download failed: degrade permanently to AVPlayer
                self.isStreamingMode = false
                self.useAVPlayerFallback = true
                self.log.error("Stream download failed; degrading permanently to AVPlayer")
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
            avPlayer?.playImmediately(atRate: requestedPlaybackRate)
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
            if state.isPlaying { startPosTimer() }
        }
    }

    func setVolume(_ v: Float) {
        guard v.isFinite else { return }
        desiredVolume = max(0, min(1, v))
        applyDesiredVolume()
    }

    private func applyDesiredVolume() {
        activePlayer.volume = desiredVolume
        if let progress = streamingSwapProgress {
            inactivePlayer.volume = desiredVolume * progress
            avPlayer?.volume = desiredVolume * (1 - progress)
        } else {
            inactivePlayer.volume = desiredVolume
            avPlayer?.volume = desiredVolume
        }
    }

    func setPlaybackRate(_ rate: Float) {
        guard rate.isFinite, (0.5...2).contains(rate) else { return }
        requestedPlaybackRate = rate
        timePitch.rate = rate
        avPlayer?.defaultRate = rate
        if avPlayer?.rate != 0 { avPlayer?.rate = rate }
    }

    func setEQ(_ bands: [EQBand]) {
        requestedEQ = bands
        if useAVPlayerFallback || isStreamingMode { return }
        applyEQ(bands)
    }

    private func applyEQ(_ bands: [EQBand]) {
        for i in 0..<min(bands.count, eq.bands.count) {
            let b = eq.bands[i]
            guard bands[i].frequency.isFinite, bands[i].gain.isFinite, bands[i].q.isFinite else {
                b.bypass = true
                continue
            }
            b.filterType = .parametric
            b.frequency = Float(max(20, min(bands[i].frequency, eq.outputFormat(forBus: 0).sampleRate / 2)))
            b.gain = max(-96, min(24, bands[i].gain))
            b.bandwidth = max(0.05, min(5, bands[i].q))
            b.bypass = false
        }
        for i in bands.count..<eq.bands.count { eq.bands[i].bypass = true }
    }

    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {
        requestedSpectrum = handler
        // Keep intent while streaming; the decoded-file handoff installs the tap.
        if useAVPlayerFallback || isStreamingMode { return }
        spectrumTap.start(on: eq, bus: 0,
                          format: eq.outputFormat(forBus: 0), handler: handler)
    }

    func removeSpectrumTap() {
        requestedSpectrum = nil
        spectrumTap.stop()
    }

    private func updateAudioProcessingAvailability() {
        if useAVPlayerFallback { state.audioProcessing = .streamOnly }
        else if isStreamingMode { state.audioProcessing = .waitingForDownload }
        else { state.audioProcessing = currentFile == nil ? .unavailable : .available }
    }

    // MARK: - Hybrid streaming: short fade from AVPlayer to AVAudioFile

    /// Starts the hand-off from AVPlayer streaming to the local AVAudioFile: background decode + ~200ms fade.
    /// Decoding runs in a `Task` (AVPlayer keeps playing; the UI is never blocked by background decoding),
    /// then the async fade stepping takes over once decoding finishes.
    private func beginStreamingSwap(to tempURL: URL, track: TrackSnapshot,
                                    loadGeneration: UInt64) {
        guard loadIsCurrent(generation: loadGeneration, trackId: track.id) else { return }
        let gen = scheduleGen
        swapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Background decode: open the AVAudioFile (AVPlayer keeps sounding; UI unblocked)
            let file: AVAudioFile?
            do { file = try AVAudioFile(forReading: tempURL) }
            catch { self.log.error("Streaming hand-off decode failed: \(error.localizedDescription)"); file = nil }
            guard let file,
                  !Task.isCancelled,
                  gen == self.scheduleGen,
                  self.loadIsCurrent(generation: loadGeneration,
                                     trackId: track.id) else { return }
            // Complete the fade on the main actor (async, yielding the actor between steps with Task.sleep)
            await self.performStreamingSwap(file: file, track: track,
                                            loadGeneration: loadGeneration)
        }
    }

    /// Performs the ~200ms crossfade hand-off from AVPlayer to AVAudioPlayerNode.
    /// scheduleSegment starts at the frame matching the AVPlayer position, crossfading volume.
    /// Runs the fade steps as async work (one `Task.sleep` per step), avoiding the Sendable/data-race
    /// hazards of Timer closures capturing across actors. Every step checks `Task.isCancelled`
    /// and the `scheduleGen` generation, terminating immediately when cancelled by `load()`/`seek()`.
    private func performStreamingSwap(file: AVAudioFile,
                                      track: TrackSnapshot,
                                      loadGeneration: UInt64) async {
        guard loadIsCurrent(generation: loadGeneration, trackId: track.id) else { return }
        let sr = file.processingFormat.sampleRate
        let rawPosition = avPlayer?.currentTime().seconds ?? 0
        let posSec = rawPosition.isFinite ? max(0, rawPosition) : 0
        let startFrame = max(0, AVAudioFramePosition(posSec * sr))
        let totalFrames = file.length
        let remaining = totalFrames - startFrame
        guard remaining > 0 else {
            // Near the end: just stop the AVPlayer — no hand-off needed
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

        streamingSwapProgress = 0
        applyDesiredVolume()
        if playbackRequested, ioCycleReady, hasAudioOutput { next.play() }

        applyEQ(requestedEQ)
        // ~200ms fade: derive every step from the latest user volume so a mute
        // during hand-off cannot be overwritten by the previous target.
        let steps = 10
        for step in 1...steps {
            if Task.isCancelled
                || myGen != self.scheduleGen
                || !loadIsCurrent(generation: loadGeneration, trackId: track.id) {
                return
            }
            if playbackRequested {
                avPlayer?.playImmediately(atRate: requestedPlaybackRate)
                if !next.isPlaying, ioCycleReady, hasAudioOutput { next.play() }
            } else {
                avPlayer?.pause()
                next.pause()
            }
            let progress = Float(step) / Float(steps)
            streamingSwapProgress = progress
            applyDesiredVolume()
            try? await Task.sleep(for: .milliseconds(20))
        }
        if Task.isCancelled
            || myGen != self.scheduleGen
            || !loadIsCurrent(generation: loadGeneration, trackId: track.id) {
            return
        }

        // Hand-off complete: tear down the AVPlayer, swap the active node, and EQ/spectrum come alive
        tearDownAVPlayer()
        isStreamingMode = false
        useAVPlayerFallback = false
        activePlayer.stop()
        activePlayer = next
        streamingSwapProgress = nil
        applyDesiredVolume()
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
        streamingSwapProgress = nil
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
        spectrumTap.stop()
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

    // MARK: - AVAudioFile primary path

    /// Decodes the local temp file and schedules it on the idle node (dual-node swap). Returns true on success.
    /// `fromFrame` selects the starting frame (0 = full track; during a streaming hand-off it is the AVPlayer position).
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
            next.volume = desiredVolume
            // On the load() path nothing has played yet; play() is not called here — PlaybackService triggers it.
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
            log.error("AVAudioFile decode failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes the AVAudioFile duration/quality info into `state` (shared by the AVAudioFile primary path).
    private func applyFileState(file: AVAudioFile, track: TrackSnapshot,
                                position: Double = 0) {
        applyEQ(requestedEQ)
        if let requestedSpectrum { installSpectrumTap(requestedSpectrum) }
        updateAudioProcessingAvailability()
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

    // MARK: - Prefetch (background download + decode for the next queued track)

    /// Background: resolve + download to a temp file, then open an AVAudioFile into the prefetch slot.
    private func preloadAndDecode(videoId: String, track: TrackSnapshot,
                                  generation: UInt64) async {
        guard prefetchIsCurrent(generation: generation, trackId: track.id) else { return }
        // File already on disk: open it directly
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
            let tempURL = await downloadWithRefresh(videoId: videoId, initialURL: resolvedURL)
            guard let tempURL,
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
            log.error("Prefetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AVPlayer path (streaming start + shared fallback)

    /// Starts AVPlayer on `url`. `fallback == true` marks the permanent fallback (download/decode failure).
    private func startAVPlayer(url: URL, fallback: Bool,
                               loadGeneration: UInt64, trackId: UUID) {
        useAVPlayerFallback = fallback
        let sourceDuration = StreamDurationPolicy.sourceDuration(url)
        if let sourceDuration { state.duration = sourceDuration }
        let item = AVPlayerItem(url: url)
        avPlayer = AVPlayer(playerItem: item)
        avPlayer?.defaultRate = requestedPlaybackRate
        applyDesiredVolume()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self,
                      self.loadIsCurrent(generation: loadGeneration, trackId: trackId),
                      let p = self.avPlayer else { return }
                self.state.position = cmTime.seconds
                if let sourceDuration {
                    self.state.duration = sourceDuration
                } else if let dur = p.currentItem?.duration,
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

    // MARK: - Download

    private var downloadTask: Task<Void, Never>?

    /// Downloads `url` to `tempURL` (local file URLs are copied directly). Remote URLs stream via `download(from:)` without loading the whole file into Data.
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
            if url.host?.hasSuffix(".googlevideo.com") == true {
                return try await downloadInRanges(from: url, to: tempURL)
            }
            let (tmp, resp) = try await session.download(from: url)
            if let http = resp as? HTTPURLResponse,
               http.statusCode == 403 {
                // Some direct media endpoints reject an unbounded request but
                // serve bounded byte ranges. AVPlayer cannot use that URL
                // directly, so assemble the file before the decoded handoff.
                return try await downloadInRanges(from: url, to: tempURL)
            }
            if let http = resp as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw PlayerError.networkError("Non-2xx response")
            }
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.moveItem(at: tmp, to: tempURL)
            return true
        } catch {
            log.error("Download failed: \(error.localizedDescription)")
            return false
        }
    }

    private func downloadWithRefresh(videoId: String, initialURL: URL) async -> URL? {
        let firstDestination = cacheFileURL(videoId: videoId, from: initialURL)
        if await downloadTo(url: initialURL, tempURL: firstDestination) {
            return firstDestination
        }
        guard !Task.isCancelled else { return nil }
        cache.invalidate(videoId: videoId, quality: currentQuality())
        guard let renewedURL = try? await resolveStreamURL(for: videoId),
              !Task.isCancelled else { return nil }
        let renewedDestination = cacheFileURL(videoId: videoId, from: renewedURL)
        return await downloadTo(url: renewedURL, tempURL: renewedDestination)
            ? renewedDestination : nil
    }

    private func downloadInRanges(from url: URL, to destination: URL) async throws -> Bool {
        let chunkSize = 1_048_576
        let maximumFileSize = 512 * 1_048_576
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw PlayerError.networkError("Unable to create media staging file")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }

        var offset = 0
        var totalSize: Int?
        repeat {
            try Task.checkCancellation()
            let end = offset + chunkSize - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 206,
                  let range = http.value(forHTTPHeaderField: "Content-Range"),
                  range.hasPrefix("bytes \(offset)-"),
                  let separator = range.lastIndex(of: "/"),
                  let size = Int(range[range.index(after: separator)...]),
                  size > 0, size <= maximumFileSize,
                  totalSize == nil || totalSize == size,
                  bytes.count == min(chunkSize, size - offset) else {
                throw PlayerError.networkError("Invalid media range response")
            }
            totalSize = size
            try handle.write(contentsOf: bytes)
            offset += bytes.count
        } while offset < (totalSize ?? 0)

        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        log.info("Recovered direct media download with bounded ranges")
        return true
    }

    // MARK: - Temp files / URL resolution

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

    /// The prefetched (background download finished) videoId / file URL, queryable externally.
    private var preparedVideoId: String?
    private var preparedTempURL: URL?

    /// Resolves the stream URL: cache first; on first failure, invalidate the cache and retry once (15s timeout).
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
            log.error("First resolution failed: \(error.localizedDescription); retrying once")
            cache.invalidate(videoId: videoId, quality: quality)
            do {
                let url = try await bridge.resolveStreamURL(
                    videoId: videoId, quality: quality, timeout: 15)
                cache.set(videoId: videoId, url: url, quality: quality)
                return url
            } catch {
                log.error("Retry also failed: \(error.localizedDescription)")
                throw PlayerError.sourceUnavailable
            }
        }
    }

    // MARK: - Position ticking / completion

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

    // MARK: - Utilities

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
