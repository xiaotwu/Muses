import Testing
import Foundation
@testable import Muses

/// 双引擎分发测试:验证 `PlaybackService` 按 `track.youTubeId` 把调用路由到
/// local / youtube 引擎,以及跨引擎切换时频谱处理器在新引擎上重装。
@MainActor
@Suite("PlaybackServiceDispatch")
struct PlaybackServiceDispatchTests {

    // MARK: - Helpers

    /// 本地曲目快照(`youTubeId = nil`)。
    private func localSnap(_ t: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, filePath: "/tmp/\(t).wav", youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                      bitDepth: 16, codec: "pcm", isLossless: false)
    }

    /// YouTube 曲目快照(`youTubeId != nil`,无本地文件路径)。
    private func youtubeSnap(_ t: String, _ vid: String) -> TrackSnapshot {
        TrackSnapshot(id: UUID(), title: t, artist: "a", albumTitle: nil,
                      durationSeconds: 1, filePath: nil, youTubeId: vid,
                      artworkHash: nil, artworkUrl: nil, sampleRate: 44100,
                      bitDepth: 16, codec: "aac", isLossless: false)
    }

    private func makePlayback(local: RecordingEngine = RecordingEngine(),
                               youtube: RecordingEngine = RecordingEngine()) -> (PlaybackService, RecordingEngine, RecordingEngine) {
        let svc = PlaybackService(localEngine: local, youtubeEngine: youtube, queue: QueueService())
        return (svc, local, youtube)
    }

    // MARK: - Tests

    @Test("load .local track dispatches to localEngine")
    func loadLocalDispatches() async throws {
        let (svc, localMock, ytMock) = makePlayback()
        let a = localSnap("a")
        svc.playTrack(a, context: [a], from: .songs)
        // playTrack 起一个 Task 执行异步 load;等一小会儿让其落定。
        try await Task.sleep(for: .milliseconds(100))
        #expect(localMock.loadCallCount == 1)
        #expect(localMock.lastLoadedTrack?.title == "a")
        #expect(ytMock.loadCallCount == 0)
    }

    @Test("load .youtube track dispatches to youtubeEngine")
    func loadYouTubeDispatches() async throws {
        let (svc, localMock, ytMock) = makePlayback()
        let y = youtubeSnap("y", "vid1")
        svc.playTrack(y, context: [y], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ytMock.loadCallCount == 1)
        #expect(ytMock.lastLoadedTrack?.title == "y")
        #expect(localMock.loadCallCount == 0)
    }

    @Test("cross-engine switch reinstalls spectrum handler")
    func spectrumReinstallOnSwitch() async throws {
        let (svc, localMock, ytMock) = makePlayback()
        // 安装频谱处理器。
        svc.installSpectrumHandler { _ in }
        #expect(localMock.spectrumTapInstalled == true)
        #expect(ytMock.spectrumTapInstalled == false)

        // 先播本地:已安装在 localMock 上。
        let a = localSnap("a")
        svc.playTrack(a, context: [a], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        #expect(localMock.spectrumTapInstalled == true)
        #expect(ytMock.spectrumTapInstalled == false)

        // 切到 YouTube:应在新引擎上重装处理器,旧引擎应被移除 tap。
        let y = youtubeSnap("y", "vid1")
        svc.playTrack(y, context: [y], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ytMock.spectrumTapInstalled == true)
        #expect(localMock.spectrumTapInstalled == false)

        // 切回本地:再次重装到 localMock。
        let b = localSnap("b")
        svc.playTrack(b, context: [b], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        #expect(localMock.spectrumTapInstalled == true)
        #expect(ytMock.spectrumTapInstalled == false)
    }

    @Test("toggle/seek delegate to currentEngine")
    func toggleAndSeekDelegate() async throws {
        let (svc, localMock, ytMock) = makePlayback()
        let a = localSnap("a")
        svc.playTrack(a, context: [a], from: .songs)
        try await Task.sleep(for: .milliseconds(100))
        svc.toggle()
        svc.seek(to: 5.0)
        #expect(localMock.toggleCallCount == 1)
        #expect(localMock.lastSeekTime == 5.0)
        #expect(ytMock.toggleCallCount == 0)
    }
}

// MARK: - Recording mock engine

/// 记录所有调用的轻量 `PlayerEngine` 实现。
/// 不依赖 AVAudioEngine,仅用于验证 PlaybackService 的分发与转发逻辑。
@MainActor
final class RecordingEngine: PlayerEngine {
    let state = PlayerState()
    var loadCallCount = 0
    var lastLoadedTrack: TrackSnapshot?
    var playCallCount = 0
    var pauseCallCount = 0
    var toggleCallCount = 0
    var seekCallCount = 0
    var lastSeekTime: Double?
    var volumeSet: Float?
    var eqBands: [EQBand]?
    var spectrumTapInstalled = false
    private var spectrumHandler: ((SpectrumFrame) -> Void)?

    func load(_ track: TrackSnapshot) async throws {
        loadCallCount += 1
        lastLoadedTrack = track
        state.track = track
    }

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }
    func toggle() { toggleCallCount += 1 }
    func seek(to time: Double) { seekCallCount += 1; lastSeekTime = time }
    func setVolume(_ v: Float) { volumeSet = v }
    func setEQ(_ bands: [EQBand]) { eqBands = bands }
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void) {
        spectrumTapInstalled = true
        spectrumHandler = handler
    }
    func removeSpectrumTap() {
        spectrumTapInstalled = false
        spectrumHandler = nil
    }
}