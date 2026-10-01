import Foundation
import AVFoundation
import Testing
@testable import Muses

@MainActor
@Suite("Playback loading pipeline", .serialized)
struct PlaybackLoadingPipelineTests {
    @Test("Clicking before warmup completes shares its in-flight resolution")
    func inFlightWarmupTransfer() async throws {
        let bridge = MockYTDlpBridge()
        bridge.streamURL = URL(string: "https://example.test/audio.m4a")!
        bridge.resolveDelaysByVideoId["selection"] = 100_000_000
        let cache = StreamURLCache()
        let resolver = StreamResolutionCoordinator(bridge: bridge, cache: cache)
        let warmup = Task { try await resolver.resolve(videoID: "selection", quality: "bestaudio") }
        while bridge.callCount == 0 { await Task.yield() }
        let foreground = Task {
            try await YTDlpRequestPriority.$interactive.withValue(true) {
                try await resolver.resolve(videoID: "selection", quality: "bestaudio")
            }
        }
        await Task.yield()
        warmup.cancel()
        let url = try await foreground.value
        #expect(url == bridge.streamURL)
        #expect(bridge.callCount == 1)
    }

    @Test("Quality identities never share a resolution")
    func independentQuality() async throws {
        let bridge = MockYTDlpBridge()
        bridge.streamURL = URL(string: "https://example.test/audio.m4a")!
        let resolver = StreamResolutionCoordinator(bridge: bridge, cache: StreamURLCache())
        _ = try await resolver.resolve(videoID: "selection", quality: "128k")
        _ = try await resolver.resolve(videoID: "selection", quality: "256k")
        #expect(bridge.callCount == 2)
    }

    @Test("Missing executable and unavailable content do not repeat a failed request")
    func permanentFailure() async {
        let bridge = MockYTDlpBridge()
        bridge.shouldFail = true
        let resolver = StreamResolutionCoordinator(bridge: bridge, cache: StreamURLCache())
        _ = try? await resolver.resolve(videoID: "selection", quality: "bestaudio")
        #expect(bridge.callCount == 1)
        #expect(!StreamResolutionPolicy.shouldRetry(YTDlpBridge.YTDlpError.exitCode(1, "Video unavailable")))
        #expect(!StreamResolutionPolicy.shouldRetry(YTDlpBridge.YTDlpError.exitCode(1, "HTTP Error 429")))
        #expect(StreamResolutionPolicy.shouldRetry(YTDlpBridge.YTDlpError.exitCode(1, "HTTP Error 503")))
    }

    @Test("Signed expiry wins over a longer configured cache TTL")
    func signedExpiry() {
        let cache = StreamURLCache()
        cache.set(videoId: "expired", url: URL(string: "https://example.test/audio?expire=1")!)
        #expect(cache.get(videoId: "expired") == nil)
    }

    @Test("Pre-download stays off by default and checks complete-file budget")
    func optionalPrecache() {
        let domain = "com.muses.tests.precache.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let bridge = MockYTDlpBridge()
        let service = StreamPrecacheService(resolution: StreamResolutionCoordinator(bridge: bridge, cache: StreamURLCache()),
            defaults: defaults, candidates: { _ in Issue.record("Disabled pre-download fetched candidates"); return [] },
            isBusy: { false })
        service.configure()
        #expect(bridge.callCount == 0)
        #expect(service.completedCount == 0)
        #expect(StreamPrecacheService.fits(size: 100, used: 900, budget: 1000))
        #expect(!StreamPrecacheService.fits(size: 101, used: 900, budget: 1000))
        #expect(!StreamPrecacheService.fits(size: Int64.max, used: 1, budget: 1000))
    }
}

@Suite("Shared stream resource", .serialized)
struct SharedStreamResourceTests {
    @Test("Native AVFoundation reads media metadata through the shared range loader")
    func nativeRangeLoader() async throws {
        ResourceMediaStub.reset()
        defer { ResourceMediaStub.reset() }
        let size: UInt32 = 44100 * 2 * 30
        var payload = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        }
        append(UInt32(36) + size)
        payload.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(44100)); append(UInt32(88200)); append(UInt16(2)); append(UInt16(16))
        payload.append(Data("data".utf8)); append(size)
        payload.append(Data(repeating: 0, count: Int(size)))
        let media = payload
        let counter = RangeCounter()
        ResourceMediaStub().respond(forHostContaining: "resource.test") { request in
            let range = request.value(forHTTPHeaderField: "Range")!
            counter.record(range)
            let start = Int(range.dropFirst(6).split(separator: "-")[0])!
            let end = min(start + Int(SharedStreamResource.chunkSize), media.count)
            return StubResponse(statusCode: 206, body: media.subdata(in: start..<end),
                headers: ["Content-Range": "bytes \(start)-\(end - 1)/\(media.count)", "Content-Type": "audio/wav"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("native.wav")
        let resource = SharedStreamResource(source: URL(string: "https://resource.test/audio")!,
            destination: destination, session: URLSession(configuration: ResourceMediaStub.makeConfig()))
        let loader = SharedStreamLoader(resource: resource)
        let duration = try await loader.asset().load(.duration)
        #expect(abs(duration.seconds - 30) < 0.01)
        #expect(counter.total < Int64(media.count) / SharedStreamResource.chunkSize)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        loader.stop()
        await resource.cancel()
    }

    @Test("Warmup, random seek, playback, and full download fetch each chunk once")
    func sharedBytes() async throws {
        ResourceMediaStub.reset()
        defer { ResourceMediaStub.reset() }
        let payload = Data((0..<700_000).map { UInt8($0 % 251) })
        let counter = RangeCounter()
        ResourceMediaStub().respond(forHostContaining: "resource.test") { request in
            let range = request.value(forHTTPHeaderField: "Range")!
            counter.record(range)
            let start = Int(range.dropFirst(6).split(separator: "-")[0])!
            let end = min(start + Int(SharedStreamResource.chunkSize), payload.count)
            return StubResponse(statusCode: 206, body: payload.subdata(in: start..<end),
                headers: ["Content-Range": "bytes \(start)-\(end - 1)/\(payload.count)", "Content-Type": "audio/mp4"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("verified.m4a")
        let resource = SharedStreamResource(source: URL(string: "https://resource.test/audio")!,
            destination: destination, session: URLSession(configuration: ResourceMediaStub.makeConfig()))
        async let first = resource.read(at: 100, length: 2000)
        async let second = resource.read(at: 200, length: 1000)
        let (a, b) = try await (first, second)
        #expect(a == payload.subdata(in: 100..<2100))
        #expect(b == payload.subdata(in: 200..<1200))
        try await resource.warm()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        _ = try await resource.read(at: 300_000, length: 1000)
        let complete = try await resource.finish()
        #expect(try Data(contentsOf: complete) == payload)
        #expect(counter.total == 3)
        #expect(counter.unique == 3)
        await resource.cancel()
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    @Test("Enabled pre-download publishes only complete files and respects existing cache budget")
    func controlledPreDownload() async throws {
        ResourceMediaStub.reset()
        defer { ResourceMediaStub.reset() }
        let payload = Data(repeating: 42, count: 8192)
        ResourceMediaStub().respond(forHostContaining: "resource.test") { _ in
            StubResponse(statusCode: 206, body: payload,
                headers: ["Content-Range": "bytes 0-8191/8192", "Content-Type": "audio/mp4"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "com.muses.tests.precache.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: PrefKey.streamPrecacheEnabled)
        defaults.set(1, forKey: PrefKey.streamPrecacheLimitGB)
        let bridge = MockYTDlpBridge()
        bridge.streamURL = URL(string: "https://resource.test/audio")!
        let track = TrackSnapshot(id: UUID(), title: "Prepared", artist: "Artist", albumTitle: nil,
            durationSeconds: 1, youTubeId: "prepared", artworkUrl: nil,
            sampleRate: 44100, bitDepth: 16, codec: "aac", isLossless: false)
        let service = StreamPrecacheService(resolution: StreamResolutionCoordinator(bridge: bridge, cache: StreamURLCache()),
            defaults: defaults, candidates: { _ in [track] }, isBusy: { false },
            session: URLSession(configuration: ResourceMediaStub.makeConfig()), directory: directory)
        service.configure()
        await service.awaitWorkForTests()
        #expect(service.completedCount == 1)
        let destination = MediaFileCache.file(videoId: "prepared", quality: "bestaudio", ext: "m4a", in: directory)
        #expect(try Data(contentsOf: destination) == payload)
        try FileManager.default.removeItem(at: destination)
        let retained = directory.appendingPathComponent("existing.m4a")
        FileManager.default.createFile(atPath: retained.path, contents: nil)
        let handle = try FileHandle(forWritingTo: retained)
        try handle.truncate(atOffset: UInt64(1_073_741_824 - 10))
        try handle.close()
        service.configure()
        await service.awaitWorkForTests()
        #expect(service.completedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        defaults.set(false, forKey: PrefKey.streamPrecacheEnabled)
        service.configure()
    }

    @Test("Malformed and oversized ranges never publish an incomplete cache")
    func rejectMalformedRange() async throws {
        ResourceMediaStub.reset()
        defer { ResourceMediaStub.reset() }
        ResourceMediaStub().respond(forHostContaining: "resource.test") { _ in
            StubResponse(statusCode: 206, body: Data([1, 2]), headers: ["Content-Range": "bytes 1-2/3"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("invalid.m4a")
        let resource = SharedStreamResource(source: URL(string: "https://resource.test/audio")!,
            destination: destination, session: URLSession(configuration: ResourceMediaStub.makeConfig()))
        do { _ = try await resource.finish(); Issue.record("Invalid range accepted") } catch {}
        await resource.cancel()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(SharedStreamResource.validatedSize(range: "bytes 0-1/999999999999", offset: 0, received: 2) == nil)
    }

    @Test("Expired addresses renew once and retain shared range consumers")
    func renewAddress() async throws {
        ResourceMediaStub.reset()
        defer { ResourceMediaStub.reset() }
        let counter = RangeCounter()
        ResourceMediaStub().respond(forHostContaining: "resource.test") { request in
            counter.record(request.url!.path)
            if request.url!.path == "/expired" { return StubResponse(statusCode: 403, body: Data()) }
            return StubResponse(statusCode: 206, body: Data([1, 2, 3]),
                headers: ["Content-Range": "bytes 0-2/3", "Content-Type": "audio/mp4"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = SharedStreamResource(source: URL(string: "https://resource.test/expired")!,
            destination: directory.appendingPathComponent("verified.m4a"),
            session: URLSession(configuration: ResourceMediaStub.makeConfig()),
            renew: { URL(string: "https://resource.test/fresh")! })
        _ = try await resource.finish()
        #expect(counter.total == 2)
        await resource.cancel()
    }
}

private final class RangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var total: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var unique: Int { lock.lock(); defer { lock.unlock() }; return Set(values).count }
}
private final class ResourceMediaStub: StubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) private static var storedRules: [StubRule] = []
    private static let storedLock = NSLock()
    override class var rules: [StubRule] { get { storedRules } set { storedRules = newValue } }
    override class var lock: NSLock { storedLock }
}
