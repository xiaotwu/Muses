import SwiftUI
import SwiftData

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    let libraryService: LibraryService
    let playbackService: PlaybackService
    let importService: YouTubeImportService
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        let container = try! makeModelContainer()
        self.modelContainer = container
        let meta = MetadataService(artworkCache: .default)
        let library = LibraryService(modelContainer: container, metadata: meta)
        self.libraryService = library
        let localEngine = LocalAudioEngine()
        let ytdlpBridge = YTDlpBridge()
        let youtubeEngine = YouTubeStreamEngine(bridge: ytdlpBridge)
        let queue = QueueService()
        queue.modelContext = container.mainContext
        queue.restore()
        self.playbackService = PlaybackService(localEngine: localEngine,
                                                 youtubeEngine: youtubeEngine,
                                                 queue: queue)
        self.importService = YouTubeImportService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        let enricher = MetadataEnricherService(modelContainer: container)
        library.enricher = enricher
        self.nowPlayingManager = NowPlayingManager(playbackService)
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // 启动后异步索引到 Spotlight
        Task { @MainActor in indexer.indexAll() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(libraryService)
                .environment(playbackService)
                .environment(importService)
                .modelContainer(modelContainer)
                .onOpenURL { url in
                    // deep link: muses://play?trackId=<id> — 阶段 2 只解析, 播放留待完善
                    if let trackId = SpotlightIndexer.trackId(from: url) {
                        AppLog.for("MusesApp").info("deep link trackId: \(trackId)")
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
