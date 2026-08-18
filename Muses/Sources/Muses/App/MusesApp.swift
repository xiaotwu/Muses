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
    let commandRegistry: CommandRegistry
    let runtimeCapabilities: RuntimeCapabilities
    let historyService: HistoryService
    let sessionService: SessionService
    let inboxService: InboxService
    let notesService: NotesService
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        // 品牌字标字体:尽早注册,使首屏 "Muses" wordmark 即用 MonteCarlo。
        FontLoader.registerMonteCarlo()
        let container = makeModelContainerWithFallback()
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
        // 笔记 & 书签(Phase 21):TrackNote/TrackBookmark/AlbumNote 读写入口;
        // 无事件总线订阅(笔记不与播放事件耦合),ffNotes 关 → 写入 no-op。
        self.notesService = NotesService(modelContainer: container)
        self.globalSearchService = GlobalSearchService(
            library: library, youTubeSearch: searchService, notes: notesService)
        self.lyricsService = LyricsService(modelContainer: container)
        self.recommendationService = RecommendationService(library: library)
        let enricher = MetadataEnricherService(modelContainer: container)
        library.enricher = enricher
        library.backfillArtists()
        library.triggerArtistEnrichment()
        self.nowPlayingManager = NowPlayingManager(playbackService)
        // 收听历史(Phase 17):订阅 playbackService.eventBus,按事件落库 ListeningEvent。
        self.historyService = HistoryService(modelContainer: container,
                                             eventBus: playbackService.eventBus)
        // 收听会话 + 崩溃恢复(Phase 18):订阅事件总线,维护 ListeningSession 行 +
        // 周期 checkpoint 到 QueueState 崩溃恢复槽;构造时检测可恢复会话供 RootView 弹对话框。
        // 须在 queue.restore() 之后构造(已在上方执行),以读取恢复的 currentTrackId/位置。
        self.sessionService = SessionService(modelContainer: container,
                                             eventBus: playbackService.eventBus,
                                             playback: playbackService,
                                             queue: queue)
        // 收件箱(Phase 20):订阅事件总线(.trackStarted→listening),维护 InboxItem 行;
        // 启动时把到期 snooze 还原为 unheard。功能开关 ffInbox 默认关 → add 为 no-op。
        self.inboxService = InboxService(modelContainer: container,
                                         eventBus: playbackService.eventBus)
        inboxService.restoreDueSnoozes()
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

        // 命令注册表:集中已有命令处理,使菜单快捷键与 Phase 24 全局热键共用同一处理。
        let registry = CommandRegistry()
        registry.register(CommandRegistry.togglePlayback) { [weak playbackService] in
            playbackService?.toggle()
        }
        registry.register(CommandRegistry.next) { [weak playbackService] in
            playbackService?.next()
        }
        registry.register(CommandRegistry.previous) { [weak playbackService] in
            playbackService?.previous()
        }
        registry.register(CommandRegistry.likeCurrent) { [weak playbackService, weak library] in
            guard let id = playbackService?.state.track?.id else { return }
            library?.toggleLike(id: id)
        }
        registry.register(CommandRegistry.toggleQueue) {
            NotificationCenter.default.post(name: .musesToggleQueue, object: nil)
        }
        registry.register(CommandRegistry.focusSearch) {
            NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
        }
        self.commandRegistry = registry
        self.runtimeCapabilities = RuntimeCapabilities()
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
                    .environment(commandRegistry)
                    .environment(runtimeCapabilities)
                    .environment(historyService)
                    .environment(sessionService)
                    .environment(inboxService)
                    .environment(notesService)
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
            // 播放控制快捷键(经 CommandRegistry 集中处理,Phase 24 全局热键复用)
            CommandGroup(after: .toolbar) {
                Divider()
                Button(tr("Play/Pause", "播放/暂停")) {
                    commandRegistry.execute(CommandRegistry.togglePlayback)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button(tr("Previous", "上一首")) {
                    commandRegistry.execute(CommandRegistry.previous)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button(tr("Next", "下一首")) {
                    commandRegistry.execute(CommandRegistry.next)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button(tr("Like Current Song", "收藏当前歌曲")) {
                    commandRegistry.execute(CommandRegistry.likeCurrent)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button(tr("Toggle Queue", "切换队列")) {
                    commandRegistry.execute(CommandRegistry.toggleQueue)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button(tr("Search", "搜索")) {
                    commandRegistry.execute(CommandRegistry.focusSearch)
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
