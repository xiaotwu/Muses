import Testing
import Foundation
@testable import Muses

/// Sleep timer service tests.
@MainActor
@Suite("SleepTimer")
struct SleepTimerTests {

    @Test("start 设置 isActive + remainingSeconds")
    func startActivatesTimer() {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        let timer = SleepTimerService(playbackService: playback)

        #expect(!timer.isActive)
        timer.start(minutes: 30)
        #expect(timer.isActive)
        #expect(timer.totalSeconds == 1800)
        #expect(timer.remainingSeconds == 1800)
    }

    @Test("cancel 重置状态")
    func cancelResetsState() {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        let timer = SleepTimerService(playbackService: playback)

        timer.start(minutes: 45)
        #expect(timer.isActive)
        timer.cancel()
        #expect(!timer.isActive)
        #expect(timer.remainingSeconds == 0)
        #expect(timer.totalSeconds == 0)
    }

    @Test("remainingFormatted 格式化正确")
    func remainingFormattedCorrect() {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(youtubeEngine: engine, queue: queue)
        let timer = SleepTimerService(playbackService: playback)

        timer.start(minutes: 1)
        // 60 seconds → "1:00"
        #expect(timer.remainingFormatted == "1:00")

        timer.start(minutes: 65)
        // 3900 seconds → "1:05:00"
        #expect(timer.remainingFormatted == "1:05:00")
    }
}

/// Stub bridge satisfying the initializer signature (never called).
@MainActor
private final class StubYTDlpBridgeForTimer: YTDlpBridgeProtocol {
    func resolveStreamURL(videoId: String, quality: String, timeout: TimeInterval) async throws -> URL {
        URL(string: "https://example.invalid/\(videoId)")!
    }
    func fetchPlaylist(url: String, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func searchYouTube(query: String, limit: Int, timeout: TimeInterval) async throws -> [YTDlpBridge.YTDlpPlaylistEntry] { [] }
    func version() async -> String? { "stub" }
}
