import Testing
import Foundation
@testable import Muses

@MainActor
@Suite("LocalAudioEngine")
struct LocalAudioEngineTests {
    @Test("loads a wav and reports duration")
    func loadReportsDuration() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-eng-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 2)
        let engine = LocalAudioEngine()
        let snap = TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 2, filePath: wav.path, youTubeId: nil,
            artworkHash: nil, artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)
        #expect(engine.state.duration > 1.5)
        #expect(engine.state.source == .local)
    }

    @Test("play then pause flips isPlaying")
    func playPause() async throws {
        let wav = FileManager.default.temporaryDirectory.appending(path: "muses-eng-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let engine = LocalAudioEngine()
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
            durationSeconds: 1, filePath: wav.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        try await engine.load(snap)
        engine.play()
        #expect(engine.state.isPlaying)
        engine.pause()
        #expect(!engine.state.isPlaying)
    }

    // MARK: - 无缝播放:prepare 预加载

    @Test("prepare preloads next file without changing current state")
    func preparePreloadsFile() async throws {
        let wavA = FileManager.default.temporaryDirectory.appending(path: "muses-prep-a-\(UUID().uuidString).wav")
        let wavB = FileManager.default.temporaryDirectory.appending(path: "muses-prep-b-\(UUID().uuidString).wav")
        try makeSilentWav(at: wavA, seconds: 2)
        try makeSilentWav(at: wavB, seconds: 3)

        let engine = LocalAudioEngine()
        let snapA = TrackSnapshot(id: UUID(), title: "Track A", artist: "a", albumTitle: nil,
            durationSeconds: 2, filePath: wavA.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        let snapB = TrackSnapshot(id: UUID(), title: "Track B", artist: "a", albumTitle: nil,
            durationSeconds: 3, filePath: wavB.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)

        try await engine.load(snapA)
        engine.play()

        // 预加载前:无预加载数据
        #expect(!engine._isPrefetched)

        await engine.prepare(snapB)

        // 预加载后:预加载数据存在,但当前播放状态不变
        #expect(engine._isPrefetched)
        #expect(engine.state.track?.title == "Track A")
        #expect(engine.state.isPlaying)
        #expect(engine.state.duration > 1.5)  // 仍是 Track A 的时长
    }

    // MARK: - 无缝播放:playPrepared 切换 activePlayer

    @Test("playPrepared swaps to prepared track with instant gapless")
    func playPreparedSwapsPlayer() async throws {
        let wavA = FileManager.default.temporaryDirectory.appending(path: "muses-swap-a-\(UUID().uuidString).wav")
        let wavB = FileManager.default.temporaryDirectory.appending(path: "muses-swap-b-\(UUID().uuidString).wav")
        try makeSilentWav(at: wavA, seconds: 2)
        try makeSilentWav(at: wavB, seconds: 3)

        // 确保 crossfade 关闭(纯无缝)
        UserDefaults.standard.set(0.0, forKey: PrefKey.crossfadeSeconds)

        let engine = LocalAudioEngine()
        let snapA = TrackSnapshot(id: UUID(), title: "Track A", artist: "a", albumTitle: nil,
            durationSeconds: 2, filePath: wavA.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        let snapB = TrackSnapshot(id: UUID(), title: "Track B", artist: "a", albumTitle: nil,
            durationSeconds: 3, filePath: wavB.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)

        try await engine.load(snapA)
        engine.play()
        let playerABefore = engine._activeIsPlayerA

        await engine.prepare(snapB)
        let ok = engine.playPrepared()
        #expect(ok)

        // state 切换到 Track B
        #expect(engine.state.track?.title == "Track B")
        #expect(engine.state.isPlaying)
        #expect(engine.state.duration > 2.5)  // Track B 的时长(~3s)

        // activePlayer 已交换
        #expect(engine._activeIsPlayerA != playerABefore)

        // 预加载已清除
        #expect(!engine._isPrefetched)
        #expect(!engine._isCrossfading)

        // playPrepared 在无预加载时返回 false
        let ok2 = engine.playPrepared()
        #expect(!ok2)
    }

    // MARK: - 交叉淡入淡出:gain ramp

    @Test("crossfade ramps volume from old to new player")
    func crossfadeGainRamp() async throws {
        let wavA = FileManager.default.temporaryDirectory.appending(path: "muses-xfade-a-\(UUID().uuidString).wav")
        let wavB = FileManager.default.temporaryDirectory.appending(path: "muses-xfade-b-\(UUID().uuidString).wav")
        try makeSilentWav(at: wavA, seconds: 5)
        try makeSilentWav(at: wavB, seconds: 5)

        // 0.1 秒交叉淡入淡出 = 5 步(每步 20ms)
        UserDefaults.standard.set(0.1, forKey: PrefKey.crossfadeSeconds)

        let engine = LocalAudioEngine()
        engine.setVolume(0.8)

        let snapA = TrackSnapshot(id: UUID(), title: "Track A", artist: "a", albumTitle: nil,
            durationSeconds: 5, filePath: wavA.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)
        let snapB = TrackSnapshot(id: UUID(), title: "Track B", artist: "a", albumTitle: nil,
            durationSeconds: 5, filePath: wavB.path, youTubeId: nil, artworkHash: nil,
            artworkUrl: nil, sampleRate: 44100, bitDepth: 16, codec: "pcm", isLossless: false)

        try await engine.load(snapA)
        engine.play()

        let volBefore = engine._activePlayerVolume  // ~0.8

        await engine.prepare(snapB)
        let ok = engine.playPrepared()
        #expect(ok)

        // 交叉淡入淡出已启动
        #expect(engine._isCrossfading)

        // 新播放器(inactivePlayer)从 0 开始
        let newVolAtStart = engine._inactivePlayerVolume
        #expect(newVolAtStart < 0.05)

        // state 已切换到 Track B(立即)
        #expect(engine.state.track?.title == "Track B")
        #expect(engine.state.isPlaying)

        // 等待交叉淡入淡出完成(0.1s ramp + 余量)
        try await Task.sleep(for: .milliseconds(300))

        // 交叉淡入淡出完成
        #expect(!engine._isCrossfading)

        // 新播放器(现 activePlayer)音量已升到 baseVolume
        let volAfter = engine._activePlayerVolume
        #expect(volAfter > volBefore - 0.15)  // 接近 0.8

        // 清理
        UserDefaults.standard.set(0.0, forKey: PrefKey.crossfadeSeconds)
    }
}