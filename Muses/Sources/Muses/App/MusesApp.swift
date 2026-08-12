import SwiftUI
import SwiftData
import Sparkle

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    let libraryService: LibraryService
    let playbackService: PlaybackService
    let importService: YouTubeImportService
    let searchService: YouTubeSearchService
    let playlistService: PlaylistService
    let sleepTimer: SleepTimerService
    let globalSearchService: GlobalSearchService
    let ytDlpBridge: YTDlpBridge
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer
    private let updaterController: SPUStandardUpdaterController

    init() {
        let container = try! makeModelContainer()
        self.modelContainer = container
        let meta = MetadataService(artworkCache: .default)
        let library = LibraryService(modelContainer: container, metadata: meta)
        self.libraryService = library
        let localEngine = LocalAudioEngine()
        let ytdlpBridge = YTDlpBridge()
        self.ytDlpBridge = ytdlpBridge
        let youtubeEngine = YouTubeStreamEngine(bridge: ytdlpBridge)
        let queue = QueueService()
        queue.modelContext = container.mainContext
        queue.restore()
        self.playbackService = PlaybackService(localEngine: localEngine,
                                                 youtubeEngine: youtubeEngine,
                                                 queue: queue)
        self.importService = YouTubeImportService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        self.searchService = YouTubeSearchService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        self.playlistService = PlaylistService(modelContainer: container)
        self.sleepTimer = SleepTimerService(playbackService: playbackService)
        self.globalSearchService = GlobalSearchService(
            library: library, youTubeSearch: searchService)
        let enricher = MetadataEnricherService(modelContainer: container)
        library.enricher = enricher
        library.backfillArtists()
        library.triggerArtistEnrichment()
        self.nowPlayingManager = NowPlayingManager(playbackService)
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // 启动后异步索引到 Spotlight
        Task { @MainActor in indexer.indexAll() }

        // Sparkle 自动更新。SUFeedURL / SUPublicEDKey 需在 .app 的 Info.plist 注入
        // (见 Resources/appcast.xml 注释)。SPM executable 无自定义 Info.plist,
        // 故仅在主 bundle 配置了 SUFeedURL 时才 startUpdater,避免 Sparkle 弹出
        // "misconfigured" 警告窗;开发/测试构建静默 no-op。
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller.startUpdater()
        }
        self.updaterController = controller
    }

    var body: some Scene {
        WindowGroup {
            ThemeApplier {
                RootView()
                    .environment(libraryService)
                    .environment(playbackService)
                    .environment(importService)
                    .environment(searchService)
                    .environment(playlistService)
                    .environment(sleepTimer)
                    .environment(globalSearchService)
                    .environment(\.ytDlpBridge, ytDlpBridge)
                    .environment(\.updater, updaterController.updater)
                    .modelContainer(modelContainer)
                    .onOpenURL { url in
                        // deep link: muses://play?trackId=<id> — Spotlight / 外部唤起播放
                        guard let trackId = SpotlightIndexer.trackId(from: url) else { return }
                        AppLog.for("MusesApp").info("deep link trackId: \(trackId)")
                        let context = modelContainer.mainContext
                        let descriptor = FetchDescriptor<Track>()
                        guard let track = (try? context.fetch(descriptor))?
                            .first(where: { $0.id == trackId }) else {
                            AppLog.for("MusesApp").warning("deep link: track \(trackId) not found")
                            return
                        }
                        let snap = TrackSnapshot(from: track)
                        playbackService.playTrack(snap, context: [snap], from: .songs)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            // 替换系统 About:弹出标准 About 面板(读 Info.plist 版本)
            CommandGroup(replacing: .appInfo) {
                Button("关于 Muses") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            // 播放控制快捷键
            CommandGroup(after: .toolbar) {
                Divider()
                Button("播放/暂停") {
                    playbackService.toggle()
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("上一首") {
                    playbackService.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("下一首") {
                    playbackService.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button("收藏当前歌曲") {
                    if let id = playbackService.state.track?.id {
                        libraryService.toggleLike(id: id)
                    }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("切换队列") {
                    NotificationCenter.default.post(name: .musesToggleQueue, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("搜索") {
                    NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                // 睡眠定时器
                Divider()
                Menu("睡眠定时器") {
                    Button("15 分钟") { sleepTimer.start(minutes: 15) }
                    Button("30 分钟") { sleepTimer.start(minutes: 30) }
                    Button("45 分钟") { sleepTimer.start(minutes: 45) }
                    Button("60 分钟") { sleepTimer.start(minutes: 60) }
                    Divider()
                    Button("取消定时器") { sleepTimer.cancel() }
                        .disabled(!sleepTimer.isActive)
                }
                if sleepTimer.isActive {
                    Text("睡眠定时器:\(sleepTimer.remainingFormatted)")
                }
            }
        }
    }
}
