import Foundation
import AVFoundation

@MainActor
final class LocalAudioEngine: PlayerEngine {
    let state = PlayerState()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 32)
    private var spectrumTap = SpectrumTap()
    private var currentFile: AVAudioFile?
    private var currentTrack: TrackSnapshot?
    private var fileFrames: AVAudioFramePosition = 0
    private var posTimer: Timer?

    init() {
        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
    }

    func load(_ track: TrackSnapshot) async throws {
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
            // 更新 state.track 以便 UI 绑定能看到当前曲目
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
            player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in self?.handleCompletion() }
            }

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

    /// 整曲 PCM 按桶聚合 `max(abs(sample))`,归一化 0...1。静态 nonisolated,不碰实例状态,可离 actor 调用。
    nonisolated static func computeWaveformPeaks(file: AVAudioFile, buckets: Int) -> [Float] {
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [Float](repeating: 0, count: buckets) }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let framesPerBuffer = min(4096, totalFrames)
        var peaks = [Float](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
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
                counts[bucket] += 1
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
        player.play()
        state.isPlaying = true
        startPosTimer()
    }

    func pause() {
        player.pause()
        state.isPlaying = false
        posTimer?.invalidate()
    }

    func toggle() { state.isPlaying ? pause() : play() }

    func seek(to time: Double) {
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

    func setVolume(_ v: Float) { player.volume = max(0, min(1, v)) }

    func setEQ(_ bands: [EQBand]) {
        // 重设频段
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
        // 频谱 tap 由调用方(PlaybackService/UI)安装一次; play() 不触碰它,
        // 避免 play 重新安装覆盖用户 handler。
        spectrumTap.start(on: eq, bus: 0, format: eq.outputFormat(forBus: 0), handler: handler)
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
        // 阶段1: 播完即停; 队列推进由 PlaybackService 监听 isPlaying 翻转
    }
}
