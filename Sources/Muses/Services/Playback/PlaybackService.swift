import Foundation

@Observable
@MainActor
final class PlaybackService {
    private(set) var eqBands: [EQBand] = EQPresets.flat
    private(set) var eqBypassed = false
    private var eqDefaults: UserDefaults?
    /// The single production playback backend is YouTubeStreamEngine.
    var state: PlayerState { engine.state }
    var transportState: PlayerState { videoSession?.state ?? state }
    private(set) var videoSession: VideoPlaybackSession?
    private var videoSuspensions: [UUID: (token: UUID, sequence: UInt64, trackId: UUID?)] = [:]
    private let engine: any PlayerEngine
    private var spectrumOwner: UUID?
    private var spectrumHandler: ((SpectrumFrame) -> Void)?
    let queue: QueueService
    /// Library service used to record play history (`recordPlay`). Optional in tests (nil skips recording).
    weak var library: LibraryService?
    /// Cross-feature playback event bus (History/Session/Context subscribe).
    /// Owned by PlaybackService as a singleton; external subscribers register via `eventBus.subscribe`.
    let eventBus = PlaybackEventBus()
    private(set) var volume: Float
    private var lastAudibleVolume: Float
    private let volumeDefaults: UserDefaults
    private var completionObserver: Task<Void, Never>?
    private var recommendationTask: Task<Void, Never>?
    var recommendationProvider: (@Sendable (String) async throws -> [MusicCatalogItem])?
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
         library: LibraryService? = nil, volumeDefaults: UserDefaults = .standard) {
        self.volumeDefaults = volumeDefaults
        self.engine = engine
        self.queue = queue
        self.library = library
        let stored = volumeDefaults.object(forKey: PrefKey.volume) as? Double
            ?? Double(volumeDefaults.object(forKey: PrefKey.volume) as? Float ?? 0.8)
        let initialVolume = stored.isFinite ? max(0, min(1, Float(stored))) : 0.8
        self.volume = initialVolume
        let remembered = volumeDefaults.double(forKey: PrefKey.lastAudibleVolume)
        self.lastAudibleVolume = initialVolume > 0 ? initialVolume
            : (remembered.isFinite && remembered > 0 ? Float(min(1, remembered)) : 0.8)
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

    /// Engine completion callback: try the gapless hand-off first (playPrepared), falling back to load.
    private func handleEngineCompletion(expected identity: PlaybackIdentity) {
        guard completionIsEligible(expected: identity) else { return }
        // Completion is one-shot for this playback identity. Any subsequent
        // callback from a superseded node/item is ignored.
        completionEligibleIdentity = nil
        // One completion per track advances the queue exactly once
        if lastCompletedTrackId == state.track?.id { return }
        lastCompletedTrackId = state.track?.id

        // Natural completion: emit .trackCompleted (HistoryService records it as completed).
        // Do not take the next() displacement path, which would misread natural completion as a skip/stop.
        postCompletedForCurrent()

        // Queue exhausted (repeat off, last track, no inserted item) → stop
        if queue.peekNext() == nil {
            playbackRequested = false
            state.isPlaying = false
            return
        }

        // Try the gapless hand-off
        if !queue.smartShuffle.enabled && engine.playPrepared() {
            // Gapless success: advance the queue to the new current track and fire the same start events as load().
            _ = queue.next()
            lastCompletedTrackId = nil
            if let started = queue.current()?.track ?? state.track {
                registerPreparedPlayback(started)
                markStarted(started)
            } else {
                prepareNext()
            }
        } else {
            // No preloaded track (YouTube or no next item): fall back to advancing without displacement recording
            advanceWithoutDisplacement()
        }
    }

    /// Natural-completion advance: no skip/stop displacement events (the completion event was already emitted).
    /// Shares the queue-advance logic with an explicit next(), bypassing displacement recording.
    private func advanceWithoutDisplacement() {
        guard let item = queue.next() else {
            playbackRequested = false
            completionEligibleIdentity = nil
            engine.pause()
            state.isPlaying = false
            return
        }
        playbackRequested = true
        scheduleLoad(item.track)
    }

    /// Preloads the next queued track into the current engine (the precondition for local gapless playback).
    private func prepareNext() {
        guard !queue.smartShuffle.enabled else { return }
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
        retireVideoSession()
        guard let track = state.track else { return }
        scheduleLoad(track)
    }

    func playTrack(_ track: TrackSnapshot, context: [TrackSnapshot], from: QueueSource) {
        retireVideoSession()
        // Direct selection: if a track is playing, record its displacement first (the user switched away from it).
        postDisplacementForCurrent()
        playbackRequested = true
        // Explicitly selecting even the current track starts a new listening
        // lifecycle instead of being reported as a resume of the old one.
        startedTrackId = nil
        queue.play(track, context: context, from: from)
        scheduleLoad(track)
    }

    func toggle() {
        if let videoSession {
            videoSession.setPlaying(!videoSession.requestedPlay)
            return
        }
        if state.error != nil, let track = state.track {
            playbackRequested = true
            scheduleLoad(track)
            return
        }
        if playbackRequested || state.isPlaying {
            pause()
        } else {
            play()
        }
    }

    var primaryAction: PlaybackPrimaryAction {
        if let videoSession { return videoSession.requestedPlay ? .pause : .play }
        if state.error != nil { return .retry }
        return playbackRequested || state.isPlaying ? .pause : .play
    }

    /// Idempotent play entry point for system commands and overlay restoration.
    /// During buffering this records intent only; `load(_:)` applies the latest
    /// intent after its await instead of overriding a newer pause.
    func play() {
        if let videoSession { videoSession.setPlaying(true); return }
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
        if let videoSession { videoSession.setPlaying(false); return }
        let wasActive = playbackRequested || state.isPlaying
        playbackRequested = false
        completionEligibleIdentity = nil
        engine.pause()
        state.isPlaying = false
        if wasActive, let track = state.track, startedTrackId == track.id {
            eventBus.post(.trackPaused(track))
        }
    }

    func beginVideoSession(videoId: String) -> VideoPlaybackSession {
        retireVideoSession()
        let start = videoPlaybackStart(for: videoId)
        let track = state.track?.youTubeId == videoId ? state.track : nil
        let session = VideoPlaybackSession(videoId: videoId, track: track, start: start)
        let token = beginNativePlaybackSuspension()
        videoSuspensions[session.id] = (token, loadSeq, state.track?.id)
        videoSession = session
        session.onVolumeChange = { [weak self, weak session] value in
            guard let self, let session, self.videoSession === session else { return }
            self.storeVolume(value)
        }
        session.onEnded = { [weak session] in session?.requestClose() }
        session.onStateChange = { [weak self, weak session] playing in
            guard let self, let session, self.videoSession === session,
                  let track = session.state.track else { return }
            if playing {
                if self.startedTrackId == track.id { self.eventBus.post(.trackResumed(track)) }
                else { self.markStarted(track) }
            } else {
                self.eventBus.post(.trackPaused(track))
            }
        }
        return session
    }

    /// Called only after WebKit has acknowledged pausing every media element.
    /// A replaced session can release its token but cannot seek a newer load.
    func finishVideoSession(_ session: VideoPlaybackSession, resume: Bool) {
        guard let owner = videoSuspensions.removeValue(forKey: session.id) else { return }
        let ownsTransport = videoSession === session
        let isCurrent = ownsTransport && owner.sequence == loadSeq
            && owner.trackId == state.track?.id && session.videoId == state.track?.youTubeId
        if ownsTransport { videoSession = nil }
        if isCurrent {
            if session.ready, session.state.error == nil {
                engine.seek(to: session.state.position)
                if let trackId = state.track?.id {
                    eventBus.post(.trackSeeked(trackId: trackId, toMs: session.state.position * 1000))
                }
            }
            playbackRequested = resume && session.requestedPlay && !session.ended
        }
        session.sendCommand = nil
        session.surface = nil
        session.onVolumeChange = nil
        session.onStateChange = nil
        session.onClose = nil
        session.onEnded = nil
        endNativePlaybackSuspension(owner.token, resume: isCurrent ? resume : true)
        if isCurrent, session.ended, session.state.error == nil {
            postCompletedForCurrent()
            startedTrackId = nil
            advanceWithoutDisplacement()
        }
    }

    private func retireVideoSession() {
        guard let session = videoSession else { return }
        // Capture displacement position before dropping transport ownership.
        if session.ready, session.state.error == nil, session.videoId == state.track?.youTubeId {
            engine.seek(to: session.state.position)
        }
        videoSession = nil
        session.requestClose()
    }

    /// Snapshot before suspension: buffering retains user intent, while a
    /// paused track stays paused when opened in the independent video surface.
    func videoPlaybackStart(for videoId: String) -> VideoPlaybackStart {
        guard state.track?.youTubeId == videoId else {
            return VideoPlaybackStart(volume: volume)
        }
        return VideoPlaybackStart(position: state.position,
                                  shouldPlay: playbackRequested || state.isPlaying,
                                  volume: volume)
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
        if let videoSession { videoSession.seek(to: time); return }
        guard time.isFinite else { return }
        engine.seek(to: time)
        if let track = state.track {
            eventBus.post(.trackSeeked(trackId: track.id, toMs: time * 1000.0))
        }
    }
    func setVolume(_ v: Float) {
        guard v.isFinite else { return }
        videoSession?.setVolume(v)
        storeVolume(v)
    }

    func toggleMute() {
        setVolume(volume > 0 ? 0 : lastAudibleVolume)
    }

    private func storeVolume(_ v: Float) {
        volume = max(0, min(1, v))
        volumeDefaults.set(Double(volume), forKey: PrefKey.volume)
        if volume > 0 {
            lastAudibleVolume = volume
            volumeDefaults.set(Double(volume), forKey: PrefKey.lastAudibleVolume)
        }
        engine.setVolume(volume)
    }
    func setEQ(_ bands: [EQBand]) {
        guard bands.count <= 32, bands.allSatisfy({ $0.frequency.isFinite && $0.gain.isFinite && $0.q.isFinite }) else { return }
        eqBands = bands
        if let data = try? JSONEncoder().encode(bands) { eqDefaults?.set(data, forKey: PrefKey.eqCurrentBands) }
        engine.setEQ(eqBypassed ? [] : bands)
    }

    func setEQBypassed(_ bypassed: Bool) {
        eqBypassed = bypassed
        eqDefaults?.set(bypassed, forKey: PrefKey.eqBypassed)
        engine.setEQ(bypassed ? [] : eqBands)
    }

    func restoreEQSettings(defaults: UserDefaults, presetBands: [EQBand]) {
        eqDefaults = defaults
        eqBypassed = defaults.bool(forKey: PrefKey.eqBypassed)
        let saved = defaults.data(forKey: PrefKey.eqCurrentBands)
            .flatMap { try? JSONDecoder().decode([EQBand].self, from: $0) }
        setEQ(saved ?? presetBands)
    }
    @discardableResult
    func installSpectrumHandler(_ h: @escaping (SpectrumFrame) -> Void) -> UUID {
        let owner = UUID()
        spectrumOwner = owner
        spectrumHandler = h
        engine.installSpectrumTap(h)
        AppLog.for("Spectrum").notice("handler count=1")
        return owner
    }
    func removeSpectrumHandler(owner: UUID? = nil) {
        if let owner, owner != spectrumOwner { return }
        spectrumOwner = nil
        spectrumHandler = nil
        engine.removeSpectrumTap()
        AppLog.for("Spectrum").notice("handler count=0")
    }

    func next() {
        retireVideoSession()
        // Explicit next: record the current track's displacement (skip/stop) first.
        // The same displacement heuristic labels queue history: below the listening threshold → .skipped, otherwise .played.
        let isSkip = currentDisplacementIsSkip()
        postDisplacementForCurrent(isSkip: isSkip)
        let historyTag: QueueHistoryState = isSkip ? .skipped : .played
        guard let item = queue.next(as: historyTag) else {
            playbackRequested = false
            completionEligibleIdentity = nil
            engine.pause()
            state.isPlaying = false
            return
        }
        playbackRequested = true
        scheduleLoad(item.track)
    }

    func previous() {
        retireVideoSession()
        // Explicit previous: record the current track's displacement first.
        postDisplacementForCurrent()
        guard let item = queue.previous() else { return }
        // If the previous track is the one already playing (at head / empty history), skip reload to avoid flicker
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
        retireVideoSession()
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
        requestSmartRecommendation()
        prepareNext()
    }

    private func markStarted(_ track: TrackSnapshot) {
        guard startedTrackId != track.id else { return }
        startedTrackId = track.id
        didStart(track)
    }

    func setSmartShuffle(_ enabled: Bool) {
        recommendationTask?.cancel()
        queue.setSmartShuffle(enabled)
        if enabled { requestSmartRecommendation() }
        else { prepareNext() }
    }

    private func requestSmartRecommendation() {
        recommendationTask?.cancel()
        guard queue.needsRecommendation, let provider = recommendationProvider,
              let current = queue.current() else { return }
        let collectionID = queue.smartShuffle.collectionID
        recommendationTask = Task { [weak self] in
            do {
                let candidates = try await provider(current.track.youTubeId)
                guard let self, !Task.isCancelled, self.queue.current()?.id == current.id,
                      self.queue.smartShuffle.collectionID == collectionID else { return }
                for candidate in candidates where candidate.kind == .song {
                    guard let entry = candidate.playableEntry else { continue }
                    let snapshot = TrackSnapshot(id: UUID(), title: entry.title, artist: entry.uploader ?? "",
                        albumTitle: entry.album, durationSeconds: entry.duration ?? 0, youTubeId: entry.id,
                        artworkUrl: candidate.artwork?.absoluteString ?? YouTubeThumbnail.urlString(videoId: entry.id),
                        sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
                    if self.queue.stageRecommendation(snapshot, sourceVideoID: current.track.youTubeId, collectionID: collectionID) { break }
                }
            } catch {
                // No trusted candidate: continue the collection unchanged.
            }
        }
    }

    /// Emits a displacement event for the current track on an explicit switch (next/previous/direct selection).
    /// Judged by listening time: `< min(30s, 20% of duration)` → `.trackSkipped`, otherwise `.trackStopped`
    /// (listened meaningfully but not to natural completion). Unknown duration degrades the threshold to 30s. Emits the event only; playback behavior is unchanged.
    /// Uses a passed-in `isSkip` when provided (avoids recomputation); computes it internally when nil.
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

    /// Natural completion (engine callback, or polling observing position reach duration): emits `.trackCompleted`,
    /// recording listenedMs as the full duration (0 when unknown).
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
                // Fully played (position reached duration) and the engine has stopped
                if self.state.position >= self.state.duration - 0.05 {
                    self.completionEligibleIdentity = nil
                    // Advance once per track completion so polling cannot trigger it twice
                    if self.lastCompletedTrackId == self.state.track?.id { continue }
                    self.lastCompletedTrackId = self.state.track?.id
                    // Natural completion: emit .trackCompleted and advance without displacement recording, avoiding a skip/stop misread.
                    self.postCompletedForCurrent()
                    // Queue exhausted (repeat off, last track, no inserted item) → stop
                    if self.queue.peekNext() == nil {
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
