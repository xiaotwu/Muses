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
/// 主路径与 `LocalAudioEngine` 共用同一套 AVAudioEngine 图
/// (AVAudioPlayerNode → AVAudioUnitEQ(32 bands) → mainMixerNode),区别在于
/// 音频素材来自 yt-dlp 解析后的远端流 URL,需先下载到本地临时文件再交给
/// `AVAudioFile` 解码。当下载或解码失败时,降级到 `AVPlayer` 直接播放远端
/// URL(此时 EQ / 频谱不可用,但能保证至少能出声)。
@MainActor
final class YouTubeStreamEngine: PlayerEngine {
    let state = PlayerState()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 32)
    private var spectrumTap = SpectrumTap()
    private var currentTrack: TrackSnapshot?
    private var currentFile: AVAudioFile?
    private var fileFrames: AVAudioFramePosition = 0
    private var posTimer: Timer?

    // AVPlayer 降级路径
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endTimeObserver: NSObjectProtocol?
    private var useAVPlayerFallback = false

    private let bridge: any YTDlpBridgeProtocol
    private let cache: StreamURLCache
    private let session: URLSession
    private let log = AppLog.for("YouTubeStreamEngine")
    private var downloadTask: Task<Void, Never>?

    /// 测试可见的降级状态查询(避免暴露内部存储)。
    var isInFallbackMode: Bool { useAVPlayerFallback }

    init(bridge: any YTDlpBridgeProtocol,
         cache: StreamURLCache = .default,
         session: URLSession = .shared) {
        self.bridge = bridge
        self.cache = cache
        self.session = session
        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - PlayerEngine

    func load(_ track: TrackSnapshot) async throws {
        // 1. 取消进行中的下载
        downloadTask?.cancel()
        downloadTask = nil

        // 2. 校验 videoId
        guard let videoId = track.youTubeId else {
            state.error = .sourceUnavailable
            throw PlayerError.sourceUnavailable
        }

        // 3. 拆除既有 AVPlayer 降级
        tearDownAVPlayer()

        // 4. 解析流 URL(缓存优先,失败重试一次)
        let resolvedURL: URL = try await resolveStreamURL(for: videoId)

        // 5. 进入缓冲态
        state.buffering = true
        state.track = track
        currentTrack = track

        // 6. 下载到临时文件
        let tempURL = streamsDir().appendingPathComponent("\(videoId).\(guessExt(from: resolvedURL))")
        let downloadOK: Bool
        do {
            let data: Data
            if resolvedURL.isFileURL {
                data = try Data(contentsOf: resolvedURL)
            } else {
                let (d, resp) = try await session.data(from: resolvedURL)
                guard let http = resp as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw PlayerError.networkError("非 2xx 响应")
                }
                data = d
            }
            try data.write(to: tempURL, options: .atomic)
            downloadOK = true
        } catch {
            log.error("下载失败,降级到 AVPlayer:\(error.localizedDescription)")
            downloadOK = false
        }

        // 7. 尝试用 AVAudioFile 解码
        if downloadOK {
            do {
                let file = try AVAudioFile(forReading: tempURL)
                currentFile = file
                fileFrames = file.length
                let sr = file.processingFormat.sampleRate
                state.duration = Double(fileFrames) / sr
                state.position = 0
                state.source = .youtube
                state.quality = AudioQualityInfo(
                    sampleRate: Int(sr),
                    bitDepth: 16,
                    codec: guessCodec(from: tempURL),
                    isLossless: false)
                state.error = nil
                state.buffering = false
                useAVPlayerFallback = false

                if !engine.isRunning {
                    do { try engine.start() }
                    catch {
                        state.error = .engineStartFailed
                        throw PlayerError.engineStartFailed
                    }
                }
                player.scheduleFile(file, at: nil) { [weak self] in
                    Task { @MainActor in self?.handleCompletion() }
                }
                return
            } catch let error as PlayerError {
                throw error
            } catch {
                log.error("AVAudioFile 解码失败,降级到 AVPlayer:\(error.localizedDescription)")
                // 落入下面的降级路径
            }
        }

        // 8. AVPlayer 降级
        useAVPlayerFallback = true
        state.buffering = false
        state.source = .youtube
        state.error = nil
        state.quality = AudioQualityInfo(
            sampleRate: 0, bitDepth: 0, codec: "native", isLossless: false)
        let item = AVPlayerItem(url: resolvedURL)
        avPlayer = AVPlayer(playerItem: item)
        avPlayer?.volume = player.volume

        // 周期时间观察器:更新 position / duration
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self, let p = self.avPlayer else { return }
                self.state.position = cmTime.seconds
                if let dur = p.currentItem?.duration,
                   dur.seconds.isFinite, dur.seconds > 0 {
                    self.state.duration = dur.seconds
                }
            }
        }

        // 播放结束通知
        endTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleCompletion() }
        }
    }

    func play() {
        if useAVPlayerFallback {
            avPlayer?.play()
            state.isPlaying = true
            return
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
        state.isPlaying = true
        startPosTimer()
    }

    func pause() {
        if useAVPlayerFallback {
            avPlayer?.pause()
            state.isPlaying = false
            return
        }
        player.pause()
        state.isPlaying = false
        posTimer?.invalidate()
    }

    func toggle() { state.isPlaying ? pause() : play() }

    func seek(to time: Double) {
        if useAVPlayerFallback {
            avPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            state.position = time
            return
        }
        guard let file = currentFile else { return }
        let sr = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(time * sr)
        player.stop()
        let remaining = fileFrames - frame
        if remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
            player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) {
                [weak self] in Task { @MainActor in self?.handleCompletion() }
            }
            // 若引擎已停(暂停过久/设备热插拔), 重启以保证 seek 后可播放
            if !engine.isRunning { try? engine.start() }
            if state.isPlaying { player.play() }
            state.position = time
        }
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        if useAVPlayerFallback { avPlayer?.volume = clamped }
        else { player.volume = clamped }
    }

    func setEQ(_ bands: [EQBand]) {
        // 降级路径下 EQ 不可用
        if useAVPlayerFallback { return }
        for i in 0..<min(bands.count, eq.bands.count) {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = Float(bands[i].frequency)
            b.gain = bands[i].gain
            b.bandwidth = bands[i].q
            b.bypass = false
        }
        for i in bands.count..<eq.bands.count { eq.bands[i].bypass = true }
    }

    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {
        // 降级路径下频谱不可用,不安装 tap(UI 显示平直)
        if useAVPlayerFallback { return }
        spectrumTap.start(on: eq, bus: 0,
                          format: eq.outputFormat(forBus: 0), handler: handler)
    }

    func removeSpectrumTap() {
        spectrumTap.stop()
    }

    // MARK: - Private helpers

    /// 解析流 URL:缓存优先,首次失败则失效缓存并重试一次。
    /// 两次都失败时设置 `state.error` 并抛出 `PlayerError.sourceUnavailable`。
    private func resolveStreamURL(for videoId: String) async throws -> URL {
        if let cached = cache.get(videoId: videoId) {
            return cached
        }
        do {
            let url = try await bridge.resolveStreamURL(
                videoId: videoId, quality: "bestaudio", timeout: 30)
            cache.set(videoId: videoId, url: url)
            return url
        } catch {
            log.error("首次解析失败:\(error.localizedDescription),将重试一次")
            cache.invalidate(videoId: videoId)
            do {
                let url = try await bridge.resolveStreamURL(
                    videoId: videoId, quality: "bestaudio", timeout: 30)
                cache.set(videoId: videoId, url: url)
                return url
            } catch {
                state.error = .sourceUnavailable
                state.buffering = false
                log.error("重试仍失败:\(error.localizedDescription)")
                throw PlayerError.sourceUnavailable
            }
        }
    }

    private func startPosTimer() {
        posTimer?.invalidate()
        posTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let file = self.currentFile else { return }
                let sr = file.processingFormat.sampleRate
                self.state.position = Double(self.player.lastRenderTime?.sampleTime ?? 0) / sr
                if self.state.position >= self.state.duration {
                    self.handleCompletion()
                }
            }
        }
    }

    private func handleCompletion() {
        posTimer?.invalidate()
        state.isPlaying = false
        // 队列推进由 PlaybackService 监听 isPlaying 翻转
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

    /// `~/Library/Caches/Muses/streams/`,按需创建。
    private func streamsDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Library/Caches/Muses/streams", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 从 URL 路径扩展名猜测文件后缀,缺省 `m4a`。
    private func guessExt(from url: URL) -> String {
        let e = url.pathExtension
        let known = ["m4a", "mp4", "webm", "ogg", "wav", "mp3", "aac", "opus"]
        if let lower = e.lowercased() as String?, known.contains(lower) {
            return lower
        }
        return "m4a"
    }

    /// 从文件后缀猜测 codec 名,用于 `AudioQualityInfo.codec`。
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