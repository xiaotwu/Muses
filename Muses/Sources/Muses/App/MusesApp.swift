import SwiftUI
import SwiftData

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    let libraryService: LibraryService
    let playbackService: PlaybackService
    private let nowPlayingManager: NowPlayingManager

    init() {
        let container = try! makeModelContainer()
        self.modelContainer = container
        let meta = MetadataService(artworkCache: .default)
        self.libraryService = LibraryService(modelContainer: container, metadata: meta)
        let engine = LocalAudioEngine()
        let queue = QueueService()
        queue.modelContext = container.mainContext
        queue.restore()
        self.playbackService = PlaybackService(engine: engine, queue: queue)
        self.nowPlayingManager = NowPlayingManager(playbackService)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(libraryService)
                .environment(playbackService)
                .modelContainer(modelContainer)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
