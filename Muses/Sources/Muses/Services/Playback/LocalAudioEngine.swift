import Foundation
import AVFoundation

@MainActor
final class LocalAudioEngine: PlayerEngine {
    let state = PlayerState()
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let preMixer = AVAudioMixerNode()  // 双播放器汇入 → EQ
    private let eq = AVAudioUnitEQ(numberOfBands: 32)
    private var spectrumTap = SpectrumTap()

    /// 当前正在播放的播放器节点。初始为 playerA。
    private var activePlayer: AVAudioPlayerNode
    /// 空闲的播放器节点,用于预加载下一首。
    private var inactivePlayer: AVAudioPlayerNode { activePlayer === playerA ? playerB : playerA }

    private var currentFile: AVAudioFile?
    private var currentTrack: TrackSnapshot?
    private var fileFrames: AVAudioFramePosition = 0

    // 预加载状态
    private var prefetchedFile: AVAudioFile?
    private var prefetchedTrack: TrackSnapshot?
    private var prefetchedFrames: AVAudioFramePosition = 0

    private var posTimer: Timer?
    private var crossfadeTimer: Timer?
    private var isCrossfading = false
    private var crossfadeStep = 0
    private var baseVolume: Float = 0.8
    /// 调度代次:每次 scheduleFile 递增,用于过滤 stop() 触发的过期完成回调。
    private var scheduleGen = 0

    // MARK: - 测试可见性(internal,仅测试用)
    internal var _isPrefetched: Bool { prefetchedFile != nil }
    internal var _isCrossfading: Bool { isCrossfading }
    internal var _activePlayerVolume: Float { activePlayer.volume }
    internal var _inactivePlayerVolume: Float { inactivePlayer.volume }
    internal var _activeIsPlayerA: Bool { activePlayer === playerA }

    var onCompletion: (@MainActor () -> Void)?

    init() {
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

    func load(_ track: TrackSnapshot) async throws {
        // 硬切换(用户手动 next/previous/play):清除预加载,停双播放器
        cancelCrossfade()
        prefetchedFile = nil
        prefetchedTrack = nil
        prefetchedFrames = 0

        guard let path = track.filePath else {
            state.error = .fileMissing("(nil)"); throw PlayerError.fileMissing("(nil)")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            state.error = .fileMissing(path); throw PlayerError.fileMissing(path)
        }
        do {
            let file = try AVAudioFile(forReading: url)
            currentFile = file
            currentTrack = track
            fileFrames = file.length
            let sr = file.processingFormat.sampleRate
            state.track = track
            state.duration = Double(fileFrames) / sr
            state.position = 0
            state.source = .local
            state.quality = AudioQualityInfo(
                sampleRate: Int(sr),
                bitDepth: track.bitDepth ?? 16,
                codec: track.codec ?? "unknown",
                isLossless: track.isLossless)
            state.error = nil

            if !engine.isRunning {
                do { try engine.start() }
                catch {
                    state.error = .engineStartFailed
                    throw PlayerError.engineStartFailed
                }
            }
            // 在 inactivePlayer 上调度新文件,然后停 activePlayer,再播放
            // inactivePlayer 并交换。完成检测由 posTimer 负责(不依赖
            // scheduleFile 回调,该回调在某些 SDK 版本会立即触发)。
            scheduleGen += 1
            let next = inactivePlayer
            next.scheduleFile(file, at: nil) { }
            activePlayer.stop()
            next.volume = effectiveVolume()
            next.play()
            activePlayer = next

            // 后台预扫描整曲波形峰值,存入 WaveformCache(命中则跳过)
            if WaveformCache.default.load(forTrackId: track.id) == nil {
                let trackId = track.id
                let filePath = path
                Task.detached(priority: .utility) {
                    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: filePath)) else { return }
                    let peaks = Self.computeWaveformPeaks(file: file, buckets: 2000)
                    try? WaveformCache.default.save(peaks, forTrackId: trackId)
                }
            }
        } catch let error as PlayerError {
            throw error
        } catch {
            state.error = .decodingFailed(error.localizedDescription)
            throw PlayerError.decodingFailed(error.localizedDescription)
        }
    }

    /// 预加载下一首:打开 AVAudioFile 存入 prefetched*,不调度不播放。
    func prepare(_ track: TrackSnapshot) async {
        guard let path = track.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return }
        prefetchedFile = file
        prefetchedTrack = track
        prefetchedFrames = file.length
    }

    /// 播放已预加载的曲目:调度到 inactivePlayer + 播放 + 交换节点 + 更新 state。
    @discardableResult
    func playPrepared() -> Bool {
        guard let file = prefetchedFile, let track = prefetchedTrack else { return false }

        // 先更新 currentTrack,使 effectiveVolume() 使用新曲目的 ReplayGain
        currentFile = file
        currentTrack = track
        fileFrames = prefetchedFrames

        // 交叉淡入淡出检查
        let crossfade = UserDefaults.standard.double(forKey: PrefKey.crossfadeSeconds)

        if crossfade > 0 {
            startCrossfade(to: file, track: track)
        } else {
            // 纯无缝:停 activePlayer,在 inactivePlayer 上调度 + 播放,交换
            scheduleGen += 1
            activePlayer.stop()
            let next = inactivePlayer
            next.scheduleFile(file, at: nil) { }
            if !engine.isRunning { try? engine.start() }
            next.volume = effectiveVolume()
            next.play()
            activePlayer = next
        }

        // 更新 state 到新曲目
        let sr = file.processingFormat.sampleRate
        state.track = track
        state.duration = Double(prefetchedFrames) / sr
        state.position = 0
        state.source = .local
        state.quality = AudioQualityInfo(
            sampleRate: Int(sr),
            bitDepth: track.bitDepth ?? 16,
            codec: track.codec ?? "unknown",
            isLossless: track.isLossless)

        // 清除预加载
        prefetchedFile = nil
        prefetchedTrack = nil
        prefetchedFrames = 0

        // 无缝切换后保持播放状态 + 启动位置追踪
        if crossfade == 0 {
            state.isPlaying = true
            startPosTimer()
        }
        // crossfade > 0 时 isPlaying 保持 true(从未停止);crossfade 完成后
        // startCrossfade 会将 activePlayer 交换为 next,position timer 继续追踪

        return true
    }

    /// 交叉淡入淡出:在 inactivePlayer 上调度新文件并播放,同时渐变两个节点的音量。
    private func startCrossfade(to file: AVAudioFile, track: TrackSnapshot) {
        isCrossfading = true
        scheduleGen += 1
        let next = inactivePlayer
        next.scheduleFile(file, at: nil) { }
        if !engine.isRunning { try? engine.start() }
        next.volume = 0
        next.play()

        let crossfade = UserDefaults.standard.double(forKey: PrefKey.crossfadeSeconds)
        let steps = Int(crossfade / 0.02)  // 20ms per step
        guard steps > 0 else {
            // 极短交叉淡入淡出:直接切换
            activePlayer.stop()
            next.volume = effectiveVolume()
            activePlayer = next
            isCrossfading = false
            return
        }
        let vol = effectiveVolume()
        crossfadeStep = 0
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.crossfadeStep += 1
                let progress = Float(self.crossfadeStep) / Float(steps)
                // activePlayer 仍是旧播放器,inactivePlayer 是新播放器
                self.activePlayer.volume = vol * (1 - progress)
                self.inactivePlayer.volume = vol * progress
                if self.crossfadeStep >= steps {
                    self.activePlayer.stop()
                    self.inactivePlayer.volume = vol
                    self.activePlayer = self.inactivePlayer
                    self.isCrossfading = false
                    self.crossfadeTimer?.invalidate()
                    self.crossfadeTimer = nil
                }
            }
        }
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        isCrossfading = false
    }

    /// 整曲 PCM 按桶聚合 `max(abs(sample))`,归一化 0...1。静态 nonisolated,不碰实例状态,可离 actor 调用。
    nonisolated static func computeWaveformPeaks(file: AVAudioFile, buckets: Int) -> [Float] {
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [Float](repeating: 0, count: buckets) }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let framesPerBuffer = min(4096, totalFrames)
        var peaks = [Float](repeating: 0, count: buckets)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBuffer)) else { return peaks }
        var framesRead: Int = 0
        while framesRead < totalFrames {
            let toRead = AVAudioFrameCount(min(framesPerBuffer, totalFrames - framesRead))
            buffer.frameLength = toRead
            do { try file.read(into: buffer) } catch { break }
            guard let ch = buffer.floatChannelData else { break }
            let n = Int(toRead)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += abs(ch[c][i]) }
                let mono = s / Float(channels)
                let bucket = min(buckets - 1, Int(Double(framesRead + i) / Double(totalFrames) * Double(buckets)))
                peaks[bucket] = max(peaks[bucket], mono)
            }
            framesRead += n
        }
        // 归一化到 0...1
        let maxPeak = peaks.max() ?? 0
        if maxPeak > 0 { for i in 0..<buckets { peaks[i] /= maxPeak } }
        return peaks
    }

    func play() {
        if !engine.isRunning { try? engine.start() }
        activePlayer.play()
        state.isPlaying = true
        startPosTimer()
    }

    func pause() {
        activePlayer.pause()
        state.isPlaying = false
        posTimer?.invalidate()
    }

    func toggle() { state.isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard let file = currentFile else { return }
        cancelCrossfade()
        let sr = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(time * sr)
        scheduleGen += 1
        activePlayer.stop()
        let remaining = fileFrames - frame
        if remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
            activePlayer.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) { }
            if !engine.isRunning { try? engine.start() }
            if state.isPlaying { activePlayer.play() }
            state.position = time
        }
    }

    func setVolume(_ v: Float) {
        baseVolume = max(0, min(1, v))
        // 交叉淡入淡出期间不覆盖渐变音量
        if !isCrossfading { activePlayer.volume = effectiveVolume() }
    }

    /// 应用 ReplayGain 后的实际音量 = baseVolume × 10^(gain/20)。
    /// replayGainEnabled 关闭或无 gain 标签时返回 baseVolume。
    private func effectiveVolume() -> Float {
        guard UserDefaults.standard.bool(forKey: PrefKey.replayGainEnabled),
              let gain = currentTrack?.replayGain else { return baseVolume }
        return baseVolume * Float(pow(10.0, gain / 20.0))
    }

    func setEQ(_ bands: [EQBand]) {
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
        spectrumTap.start(on: eq, bus: 0, format: eq.outputFormat(forBus: 0), handler: handler)
    }

    func removeSpectrumTap() {
        spectrumTap.stop()
    }

    private func startPosTimer() {
        posTimer?.invalidate()
        posTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let file = self.currentFile else { return }
                let sr = file.processingFormat.sampleRate
                self.state.position = Double(self.activePlayer.lastRenderTime?.sampleTime ?? 0) / sr
                if self.state.position >= self.state.duration {
                    self.handleCompletion()
                }
            }
        }
    }

    private func handleCompletion() {
        // 交叉淡入淡出期间忽略旧播放器的完成回调
        if isCrossfading { return }
        posTimer?.invalidate()
        state.isPlaying = false
        // 通知 PlaybackService 推进队列 + playPrepared + prepare 下一首
        onCompletion?()
    }
}
