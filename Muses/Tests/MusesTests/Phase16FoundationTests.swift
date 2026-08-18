import Foundation
import Testing
import SwiftData
@testable import Muses

/// Phase 16 基础层验收:新增可选字段(lightweight migration 产物)读写正确,
/// 向后兼容 JSON 解码,以及容器构造不破坏既有 schema。
@Suite("Phase 16 Foundation")
@MainActor
struct Phase16FoundationTests {

    // MARK: - Track / TrackSnapshot 新字段

    @Test("Track 接受 bitRate/channels 可选字段并默认 nil")
    func trackBitRateChannelsDefault() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        let track = Track(source: .local, title: "t", artist: "a", durationMs: 1000,
                          filePath: "/x.wav", codec: "pcm", isLossless: false)
        ctx.insert(track)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<Track>()).first
        #expect(fetched?.bitRate == nil)
        #expect(fetched?.channels == nil)
    }

    @Test("Track bitRate/channels 持久化往返")
    func trackBitRateChannelsRoundTrip() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        let track = Track(source: .local, title: "t", artist: "a", durationMs: 1000,
                          filePath: "/x.flac", codec: "flac", isLossless: true,
                          bitRate: 1411000, channels: 2)
        ctx.insert(track)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<Track>()).first
        #expect(fetched?.bitRate == 1411000)
        #expect(fetched?.channels == 2)
    }

    @Test("TrackSnapshot 携带 bitRate/channels 并往返编解码")
    func snapshotBitRateChannels() throws {
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1.0, filePath: "/x", youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil,
                                 sampleRate: 96000, bitDepth: 24, codec: "flac",
                                 isLossless: true, liked: true, lyrics: nil, replayGain: nil,
                                 bitRate: 1411000, channels: 2)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(back.bitRate == 1411000)
        #expect(back.channels == 2)
    }

    @Test("TrackSnapshot 解码不含 bitRate/channels 的旧 JSON 仍成功(向后兼容)")
    func snapshotBackwardCompat() throws {
        // 旧版 JSON:无 bitRate/channels 字段(模拟 Phase 15 之前的 QueueState 持久化)
        let old =
            """
            {"id":"00000000-0000-0000-0000-000000000002","title":"t","artist":"a",
             "albumTitle":null,"durationSeconds":1.0,"filePath":"/x","youTubeId":null,
             "artworkHash":null,"artworkUrl":null,"sampleRate":44100,"bitDepth":16,
             "codec":"pcm","isLossless":false,"liked":false,"lyrics":null,"replayGain":null}
            """
        let snap = try JSONDecoder().decode(TrackSnapshot.self, from: Data(old.utf8))
        #expect(snap.bitRate == nil)
        #expect(snap.channels == nil)
        #expect(snap.sampleRate == 44100)
    }

    // MARK: - QueueItem 新字段 + 向后兼容

    @Test("QueueItem locked/groupId/priority 默认值")
    func queueItemDefaults() {
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1.0, filePath: nil, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil,
                                 sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        let item = QueueItem(track: snap, source: .local, fromContext: .songs)
        #expect(item.locked == false)
        #expect(item.groupId == nil)
        #expect(item.priority == nil)
    }

    @Test("QueueItem 解码不含 locked/groupId/priority 的旧 JSON 仍成功")
    func queueItemBackwardCompat() throws {
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                 durationSeconds: 1.0, filePath: nil, youTubeId: nil,
                                 artworkHash: nil, artworkUrl: nil,
                                 sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        // 先用新编码器产出含新字段的 JSON,再手工构造一个去掉新字段的"旧"JSON。
        let item = QueueItem(track: snap, source: .local, fromContext: .songs,
                             locked: true, groupId: UUID(), priority: 5)
        let encoded = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(QueueItem.self, from: encoded)
        #expect(back.locked == true)
        #expect(back.priority == 5)

        // 旧 JSON(无 locked/groupId/priority):
        let old =
            """
            {"id":"00000000-0000-0000-0000-000000000003",
             "track":\(String(data: try JSONEncoder().encode(snap), encoding: .utf8)!),
             "source":"local","queuedAt":0,"fromContext":"songs"}
            """
        let oldItem = try JSONDecoder().decode(QueueItem.self, from: Data(old.utf8))
        #expect(oldItem.locked == false)
        #expect(oldItem.groupId == nil)
        #expect(oldItem.priority == nil)
    }

    // MARK: - QueueState 新字段

    @Test("QueueState currentTrackId/lastPositionMs 可选字段持久化")
    func queueStateNewFields() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        let id = UUID()
        let row = QueueState(itemsJSON: "[]", currentIndex: 0, upNextJSON: "[]",
                             historyJSON: "[]", repeatModeRaw: "off", shuffle: false,
                             currentTrackId: id, lastPositionMs: 12.5)
        ctx.insert(row)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<QueueState>()).first
        #expect(fetched?.currentTrackId == id)
        #expect(fetched?.lastPositionMs == 12.5)
    }

    @Test("QueueState 不传新字段时默认 nil(向后兼容现有持久化)")
    func queueStateDefaults() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        let row = QueueState(itemsJSON: "[]", currentIndex: 0, upNextJSON: "[]",
                             historyJSON: "[]", repeatModeRaw: "off", shuffle: false)
        ctx.insert(row)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<QueueState>()).first
        #expect(fetched?.currentTrackId == nil)
        #expect(fetched?.lastPositionMs == nil)
    }

    // MARK: - 完整 schema 仍可加载(10 个模型)

    @Test("容器构造注册全部 10 个模型类型且可空查询")
    func fullSchemaLoads() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<Track>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Album>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Artist>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<ScanRoot>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<QueueState>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<EQPreset>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<YouTubeImport>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<YouTubeImportItem>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Playlist>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PlaylistItem>()).isEmpty)
    }

    // MARK: - PlaybackEventBus

    @Test("PlaybackEventBus 派发事件给订阅者,取消后不再收到")
    func eventBusDispatch() {
        let bus = PlaybackEventBus()
        var received: [PlaybackEvent] = []
        let token = bus.subscribe { received.append($0) }
        bus.post(.trackStarted(TrackSnapshot(id: UUID(), title: "t", artist: "a",
                                              albumTitle: nil, durationSeconds: 1,
                                              filePath: nil, youTubeId: nil,
                                              artworkHash: nil, artworkUrl: nil,
                                              sampleRate: nil, bitDepth: nil, codec: nil,
                                              isLossless: false)))
        bus.post(.queueChanged)
        bus.unsubscribe(token)
        bus.post(.queueChanged)
        #expect(received.count == 2)
        if case .trackStarted = received[0] {} else { Issue.record("expected trackStarted") }
    }

    @Test("PlaybackService load 成功后经 eventBus 发出 trackStarted")
    func playbackPostsStarted() async throws {
        let container = try makeModelContainer(inMemory: true)
        let library = LibraryService(modelContainer: container,
                                     metadata: MetadataService(artworkCache: .default))
        let queue = QueueService()
        let local = LocalAudioEngine()
        let yt = YouTubeStreamEngine(bridge: YTDlpBridge())
        let playback = PlaybackService(localEngine: local, youtubeEngine: yt,
                                        queue: queue, library: library)
        var started: [UUID] = []
        let token = playback.eventBus.subscribe { e in
            if case .trackStarted(let s) = e { started.append(s.id) }
        }
        // 用真实静音 WAV 文件,使 LocalAudioEngine.load 成功,从而走到 trackStarted 发布点。
        let wav = FileManager.default.temporaryDirectory
            .appending(path: "muses-p16-\(UUID().uuidString).wav")
        try makeSilentWav(at: wav, seconds: 1)
        let snap = TrackSnapshot(id: UUID(), title: "t", artist: "a", albumTitle: nil,
                                  durationSeconds: 1.0, filePath: wav.path, youTubeId: nil,
                                  artworkHash: nil, artworkUrl: nil,
                                  sampleRate: 44100, bitDepth: 16, codec: "pcm",
                                  isLossless: false)
        playback.playTrack(snap, context: [snap], from: .songs)
        // 等待 async load + play 完成
        try await Task.sleep(for: .milliseconds(400))
        playback.eventBus.unsubscribe(token)
        try? FileManager.default.removeItem(at: wav)
        #expect(started.contains(snap.id))
    }

    // MARK: - CommandRegistry

    @Test("CommandRegistry 注册并执行命令;未注册命令为 no-op")
    func commandRegistryExecute() {
        let registry = CommandRegistry()
        var fired = false
        registry.register(CommandRegistry.togglePlayback) { fired = true }
        registry.execute(CommandRegistry.togglePlayback)
        #expect(fired)
        // 未注册的命令不会崩溃
        registry.execute("nonexistent")
        #expect(registry.has(CommandRegistry.togglePlayback))
        #expect(!registry.has("nonexistent"))
    }

    // MARK: - RuntimeCapabilities

    @Test("RuntimeCapabilities 报告 macOS 14+ 预期支持状态")
    func capabilities() {
        let caps = RuntimeCapabilities()
        #expect(caps.isUsable(caps.globalHotkeys))
        #expect(caps.isUsable(caps.mediaKeys))
        #expect(caps.isUsable(caps.tray))
        #expect(caps.isUsable(caps.miniWindow))
        #expect(caps.isUsable(caps.desktopLyrics))
        // limited 仍算 usable
        #expect(caps.outputDeviceSwitching == .limited)
        #expect(caps.wordSyncedLyrics == .limited)
        // 天气不支持
        #expect(!caps.isUsable(caps.weatherContext))
    }

    // MARK: - 迁移安全保护

    @Test("makeModelContainerWithFallback 在全新临时路径返回可用容器(不触碰真实 DB)")
    func fallbackReturnsUsable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "muses-fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "muses.sqlite")
        let container = makeModelContainerWithFallback(storeURL: store)
        let ctx = ModelContext(container)
        // 在全新 store 上插入并保存新字段,验证往返(.first 即此唯一行)。
        let track = Track(source: .local, title: "t", artist: "a", durationMs: 1,
                          bitRate: 320000, channels: 2)
        ctx.insert(track)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<Track>()).first
        #expect(fetched?.bitRate == 320000)
        #expect(fetched?.channels == 2)
    }

    @Test("backupCorruptStore 备份原文件且不删除(临时目录,不触碰真实 DB)")
    func backupPreservesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "muses-bk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "muses.sqlite")
        // 伪造一个"损坏"的 store 文件及其 -wal 伴随文件。
        try Data("[not a sqlite db]".utf8).write(to: store)
        try Data().write(to: dir.appending(path: "muses.sqlite-wal"))
        backupCorruptStore(at: store)
        // 原文件仍在(未被删除/覆盖)。
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "muses.sqlite-wal").path))
        // 出现 *-corrupt-*.sqlite{,-wal} 备份。
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("corrupt") }
        #expect(entries.contains { $0.hasSuffix(".sqlite") })
        #expect(entries.contains { $0.hasSuffix(".sqlite-wal") })
    }
}