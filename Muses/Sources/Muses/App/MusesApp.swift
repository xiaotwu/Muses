import SwiftUI
import SwiftData

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
    let lyricsService: LyricsService
    let recommendationService: RecommendationService
    let ytDlpBridge: YTDlpBridge
    let updateService: UpdateService
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        // 品牌字标字体:尽早注册,使首屏 "Muses" wordmark 即用 MonteCarlo。
        FontLoader.registerMonteCarlo()
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
                                                 queue: queue,
                                                 library: library)
        self.importService = YouTubeImportService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        self.searchService = YouTubeSearchService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        self.playlistService = PlaylistService(modelContainer: container)
        self.sleepTimer = SleepTimerService(playbackService: playbackService)
        self.globalSearchService = GlobalSearchService(
            library: library, youTubeSearch: searchService)
        self.lyricsService = LyricsService(modelContainer: container)
        self.recommendationService = RecommendationService(library: library)
        let enricher = MetadataEnricherService(modelContainer: container)
        library.enricher = enricher
        library.backfillArtists()
        library.triggerArtistEnrichment()
        self.nowPlayingManager = NowPlayingManager(playbackService)
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // 启动后异步索引到 Spotlight
        Task { @MainActor in indexer.indexAll() }

        // GitHub Release 更新检查(替换原 Sparkle 自动更新)。
        // 偏好 `checkForUpdates` 控制是否自动检查;24h 内不重复检查。
        let updater = UpdateService()
        self.updateService = updater
        Task { @MainActor in
            // 启动 3s 后再检查,避免与首屏加载/索引抢资源。
            try? await Task.sleep(for: .milliseconds(3000))
            await updater.checkIfDue()
        }
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
                    .environment(lyricsService)
                    .environment(recommendationService)
                    .environment(\.ytDlpBridge, ytDlpBridge)
                    .environment(updateService)
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
                Button(tr("About Muses", "关于 Muses")) {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            // 播放控制快捷键
            CommandGroup(after: .toolbar) {
                Divider()
                Button(tr("Play/Pause", "播放/暂停")) {
                    playbackService.toggle()
                }
                .keyboardShortcut("p", modifiers: .command)

                Button(tr("Previous", "上一首")) {
                    playbackService.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button(tr("Next", "下一首")) {
                    playbackService.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button(tr("Like Current Song", "收藏当前歌曲")) {
                    if let id = playbackService.state.track?.id {
                        libraryService.toggleLike(id: id)
                    }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button(tr("Toggle Queue", "切换队列")) {
                    NotificationCenter.default.post(name: .musesToggleQueue, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button(tr("Search", "搜索")) {
                    NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                // 睡眠定时器
                Divider()
                Menu(tr("Sleep Timer", "睡眠定时器")) {
                    Button(tr("15 min", "15 分钟")) { sleepTimer.start(minutes: 15) }
                    Button(tr("30 min", "30 分钟")) { sleepTimer.start(minutes: 30) }
                    Button(tr("45 min", "45 分钟")) { sleepTimer.start(minutes: 45) }
                    Button(tr("60 min", "60 分钟")) { sleepTimer.start(minutes: 60) }
                    Divider()
                    Button(tr("Cancel Timer", "取消定时器")) { sleepTimer.cancel() }
                        .disabled(!sleepTimer.isActive)
                }
                if sleepTimer.isActive {
                    Text("\(tr("Sleep Timer", "睡眠定时器")):\(sleepTimer.remainingFormatted)")
                }
            }
        }
    }
}
