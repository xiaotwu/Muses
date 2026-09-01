import SwiftUI
import SwiftData
import AppKit

@main
struct MusesApp: App {
    let modelContainer: ModelContainer
    /// True when the on-disk library could not be opened and the session is empty in-memory.
    let usedInMemoryFallback: Bool
    let libraryService: LibraryService
    let playbackService: PlaybackService
    let importService: YouTubeImportService
    let searchService: YouTubeSearchService
    let playlistService: PlaylistService
    let sleepTimer: SleepTimerService
    let globalSearchService: GlobalSearchService
    let lyricsService: LyricsService
    let ytDlpBridge: YTDlpBridge
    let updateService: UpdateService
    let commandRegistry: CommandRegistry
    let runtimeCapabilities: RuntimeCapabilities
    let historyService: HistoryService
    let contextService: ContextService
    let automationService: AutomationService
    let sessionService: SessionService
    let inboxService: InboxService
    let notesService: NotesService
    let focusService: FocusService
    let audioDeviceService: AudioDeviceService
    // Phase D3 — Home 动态发现:provider 抽象 + cache-first + per-section failure。
    let homeDiscoveryService: HomeDiscoveryService
    /// Optional, isolated YouTube Music Web Home control plane. It is
    /// build-gated, user-consented, and never participates in playback.
    let webHomeSessionController: WebHomeSessionController
    // Phase D5 — New 情境化推荐:History/Context/Sessions/Focus/Inbox/Library 确定性打分。
    let situationalRecommendationService: SituationalRecommendationService
    // P2 — YouTube 账户(真实 Google OAuth 2.0 PKCE + Data API):用于 Home 个性化信号
    // (订阅频道/喜欢的视频→艺术家名),凭证与令牌存 Keychain,最小只读 scope,永不阻断播放。
    let youTubeAccountService: YouTubeAccountService
    let youTubePlaylistSyncService: YouTubePlaylistSyncService
    let youTubeCatalogService: YouTubeCatalogService
    // Phase 24 — 原生桌面集成:全局热键 / 菜单栏托盘 / 桌面歌词 / 迷你播放器。
    let globalHotkeyService: GlobalHotkeyService
    let trayController: TrayController
    let desktopLyricsController: DesktopLyricsController
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        MusesSingleInstance.yieldIfOtherInstanceRunning()
        // 品牌字标字体:尽早注册,使首屏 "Muses" wordmark 即用 MonteCarlo。
        FontLoader.registerMonteCarlo()
        YTCookieSource.migrateChromeIfNeeded()
        // P5 issue #7 — 应用内功能标志默认开启(用户显式选择「全部启用」)。
        // 仅注册未显式设置的键:用户曾在设置中关闭的项保持关闭(不回退其选择)。
        // 全局热键 / 迷你播放器 / 桌面歌词仍默认关;菜单栏图标默认开。
        UserDefaults.standard.register(defaults: FeatureFlagDefaults.enabledByDefault)
        UserDefaults.standard.register(defaults: WebHomePreferenceDefaults.values)
        #if DEBUG
        let storeLoad: MusesStoreLoadResult
        if ProcessInfo.processInfo.environment["MUSES_IN_MEMORY_STORE"] == "1" {
            storeLoad = MusesStoreLoadResult(
                container: try! makeModelContainer(inMemory: true),
                usedInMemoryFallback: false
            )
        } else {
            storeLoad = makeYouTubeNativeModelContainerWithFallback()
        }
        #else
        let storeLoad = makeYouTubeNativeModelContainerWithFallback()
        #endif
        self.modelContainer = storeLoad.container
        self.usedInMemoryFallback = storeLoad.usedInMemoryFallback
        let container = storeLoad.container
        let library = LibraryService(modelContainer: container)
        self.libraryService = library
        let catalogService = YouTubeCatalogService(modelContainer: container)
        self.youTubeCatalogService = catalogService
        let ytdlpBridge = YTDlpBridge()
        self.ytDlpBridge = ytdlpBridge
        let youtubeEngine = YouTubeStreamEngine(bridge: ytdlpBridge)
        let queue = QueueService()
        queue.modelContext = container.mainContext
        queue.restore()
        self.playbackService = PlaybackService(
            youtubeEngine: youtubeEngine,
            queue: queue,
            library: library
        )
        self.importService = YouTubeImportService(bridge: ytdlpBridge,
                                                  modelContainer: container,
                                                  catalog: catalogService)
        self.searchService = YouTubeSearchService(bridge: ytdlpBridge,
                                                  modelContainer: container)
        self.playlistService = PlaylistService(modelContainer: container)
        self.sleepTimer = SleepTimerService(playbackService: playbackService)
        // 笔记 & 书签(Phase 21):TrackNote/TrackBookmark 读写入口;
        // 无事件总线订阅(笔记不与播放事件耦合),ffNotes 关 → 写入 no-op。
        self.notesService = NotesService(modelContainer: container)
        self.globalSearchService = GlobalSearchService(
            library: library, catalog: catalogService,
            youTubeSearch: searchService, notes: notesService)
        self.lyricsService = LyricsService(modelContainer: container)
        self.nowPlayingManager = NowPlayingManager(playbackService, library: library, queue: queue)
        // 上下文监听(Phase 23 §10.2):ffContext 默认开(P5),best-effort 捕获本地时间/
        // 输出设备/耳机启发式。前台应用 bundle id 仍需 contextTrackActiveApp 显式开启。
        // 绝不记录窗口标题/URL/内容。capture() 关闭时返回 nil,HistoryService 存 nil。
        let contextService = ContextService()
        self.contextService = contextService
        // 收听历史(Phase 17):订阅 playbackService.eventBus,按事件落库 ListeningEvent。
        // Phase 23:注入 contextProvider 使 ListeningEvent.contextSummaryJSON 在终结时填充。
        self.historyService = HistoryService(modelContainer: container,
                                             eventBus: playbackService.eventBus,
                                             contextProvider: { [weak contextService] in
            contextService?.capture()
        })
        // Listening-session crash recovery is constructed after queue.restore()
        // so it can load the persisted current item and position while paused.
        self.sessionService = SessionService(modelContainer: container,
                                             eventBus: playbackService.eventBus,
                                             playback: playbackService,
                                             queue: queue)
        // 专注模式(Phase 25 §10.9):订阅无关,持运行态;关联回当前 ListeningSession(只读)。
        // ffFocusMode 默认开(P5);未开始会话时 isActive 保持 false,不抑制发现表面。
        self.focusService = FocusService(modelContainer: container,
                                         eventBus: playbackService.eventBus,
                                         playback: playbackService,
                                         sessionService: sessionService)
        // 音频输出设备(Phase 26 §10.10):Core Audio 枚举/切换(best-effort),2s 轮询检测默认变更。
        let audioDevices = AudioDeviceService(eventBus: playbackService.eventBus)
        self.audioDeviceService = audioDevices
        Task { @MainActor in audioDevices.startPolling() }
        // 收件箱(Phase 20):订阅事件总线(.trackStarted→listening),维护 InboxItem 行;
        // 启动时把到期 snooze 还原为 unheard。功能开关 ffInbox 默认开(P5)。
        self.inboxService = InboxService(modelContainer: container,
                                         eventBus: playbackService.eventBus)
        inboxService.restoreDueSnoozes()
        // 上下文自动化(Phase 23 §12):订阅事件总线,匹配 AutomationRule 触发器/条件/动作。
        // ffAutomation 默认开(P5)。动作处理器接入 library/inbox/playback。
        self.automationService = AutomationService(
            modelContainer: container,
            eventBus: playbackService.eventBus,
            contextProvider: { [weak contextService] in contextService?.capture() },
            actionHandler: AutomationService.makeDefaultActionHandler(
                library: library, inbox: inboxService, playback: playbackService))
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // 启动后异步索引到 Spotlight
        Task { @MainActor in indexer.indexAll() }

        // Phase D3 — Home 动态发现服务:默认 provider 基于 yt-dlp 主题化 ytsearch,
        // 经 searchService.search 闭包注入(闭包内调用 @MainActor YTDlpBridge)。
        // ffDiscovery 默认开(P5);关闭时 load() no-op,HomeView 回退现有行为。
        // 注:struct init 中 escaping 闭包不可捕获未完全初始化的 self,故用本地绑定。
        let ytSearchSvc = searchService
        let ytBridge = ytdlpBridge
        let discoveryProvider = YTDlpDiscoveryProvider(
            fetchPlaylist: { url in try await ytBridge.fetchPlaylist(url: url) },
            search: { query, limit in try await ytSearchSvc.search(query: query, limit: limit) }
        )
        // P2 — YouTube 账户服务:Google OAuth 2.0 PKCE + YouTube Data API v3。
        // OAuth 客户端配置由应用构建持有，令牌存 macOS Keychain；用户只在
        // 默认浏览器中授权。OAuth 永不阻断访客浏览、导入或播放。
        let youTubeAccount = YouTubeAccountService()
        self.youTubeAccountService = youTubeAccount
        let playlistSync = YouTubePlaylistSyncService(
            modelContainer: container, account: youTubeAccount)
        self.youTubePlaylistSyncService = playlistSync
        do {
            try playlistSync.purgeExpiredRecentlyDeleted()
        } catch {
            AppLog.for("MusesApp").warning(
                "Recently Deleted cleanup failed: \(error.localizedDescription)")
        }
        let accountHomeProvider = YouTubeAccountHomeProvider(
            base: discoveryProvider,
            snapshot: { [weak youTubeAccount] in youTubeAccount?.account })
        let webHome = WebHomeSessionController(
            currentChannelIDProvider: { [weak youTubeAccount] in
                youTubeAccount?.activeChannelID
            })
        self.webHomeSessionController = webHome
        // A+B Home: official-account/public discovery remains the stable
        // baseline. The optional Web adapter has its own process, consent,
        // normalized snapshot, and physical cache partition.
        let layeredHomeProvider = LayeredHomeProvider(
            baseline: accountHomeProvider,
            webEnhancement: webHome.isBuildEnabled ? webHome : nil)
        self.homeDiscoveryService = HomeDiscoveryService(
            provider: layeredHomeProvider,
            library: library,
            historyService: historyService,
            youTubeSignals: { [weak youTubeAccount] in
                await youTubeAccount?.signals()
            },
            accountChannelIDProvider: { [weak youTubeAccount] in
                youTubeAccount?.activeChannelID
            })
        // Phase D5 — New 情境化推荐(只读 History/Context/Focus/Inbox/Library + 已导入 YouTube)。
        // ffSituationalNew 默认开(P5);关闭时 compute() 返回空,NewView 回退 RecommendationService。
        self.situationalRecommendationService = SituationalRecommendationService(
            library: library,
            historyService: historyService,
            contextService: contextService,
            focusService: focusService,
            inboxService: inboxService,
            modelContainer: container)

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

        // Phase 24 — 桌面集成服务构造 + 接线。
        // 热键派发器:既有命令经 commandRegistry;桌面专属动作(volume/mini/lyrics/focus/inbox)直接调用。
        // 注:struct init 中 escaping 闭包不可捕获 self,故用本地绑定经 capture list 弱引用。
        let playback = playbackService
        let lib = library
        let inbox = inboxService
        let lyricsSvc = lyricsService
        GlobalHotkeyService.sharedDispatcher = { [weak registry, weak playback, weak inbox] action in
            switch action {
            case GlobalHotkeyService.actionPlayPause, GlobalHotkeyService.actionNext,
                 GlobalHotkeyService.actionPrevious, GlobalHotkeyService.actionLike:
                registry?.execute(action)
            case GlobalHotkeyService.actionVolumeUp:
                playback?.setVolume(min(1, (playback?.volume ?? 0.8) + 0.05))
            case GlobalHotkeyService.actionVolumeDown:
                playback?.setVolume(max(0, (playback?.volume ?? 0.8) - 0.05))
            case GlobalHotkeyService.actionMute:
                playback?.setVolume(playback?.volume ?? 0 > 0 ? 0 : 0.8)
            case GlobalHotkeyService.actionAddToInbox:
                if let snap = playback?.state.track { inbox?.add(snap, source: .automation) }
            case GlobalHotkeyService.actionShowHidePlayer:
                MusesSingleInstance.orderFrontMainWindow()
            case GlobalHotkeyService.actionShowMiniPlayer:
                NotificationCenter.default.post(name: .musesOpenMiniPlayer, object: nil)
            case GlobalHotkeyService.actionShowLyrics:
                NotificationCenter.default.post(name: .musesToggleDesktopLyrics, object: nil)
            case GlobalHotkeyService.actionToggleFocus:
                NotificationCenter.default.post(name: .musesToggleFocusMode, object: nil)
            default: break
            }
        }
        let hotkeys = GlobalHotkeyService(
            enabledProvider: { UserDefaults.standard.bool(forKey: PrefKey.ffGlobalHotkeys) },
            shortcutProvider: { GlobalHotkeyService.loadShortcuts() },
            dispatcher: { GlobalHotkeyService.sharedDispatcher?($0) })
        self.globalHotkeyService = hotkeys

        let tray = TrayController(
            trackProvider: { [weak playback] in playback?.state.track },
            isPlayingProvider: { [weak playback] in playback?.state.isPlaying ?? false },
            onPlayPause: { [weak registry] in registry?.execute(CommandRegistry.togglePlayback) },
            onNext: { [weak registry] in registry?.execute(CommandRegistry.next) },
            onPrevious: { [weak registry] in registry?.execute(CommandRegistry.previous) },
            onLike: { [weak registry] in registry?.execute(CommandRegistry.likeCurrent) },
            onAddToInbox: { [weak playback, weak inbox] in
                if let snap = playback?.state.track { inbox?.add(snap, source: .automation) }
            },
            onOpenMini: { NotificationCenter.default.post(name: .musesOpenMiniPlayer, object: nil) },
            onOpenMain: {
                MusesSingleInstance.orderFrontMainWindow()
            },
            onQuit: { NSApp.terminate(nil) })
        self.trayController = tray
        let desktopLyrics = DesktopLyricsController()
        self.desktopLyricsController = desktopLyrics

        // 启动时按当前开关状态初始化各桌面服务;之后由 Settings 切换通知刷新。
        Task { @MainActor in
            hotkeys.sync()
            tray.setEnabled(UserDefaults.standard.bool(forKey: PrefKey.ffTray))
            desktopLyrics.setEnabled(
                UserDefaults.standard.bool(forKey: PrefKey.ffDesktopLyrics),
                playback: playback, library: lib, lyrics: lyricsSvc)
        }
        // 托盘菜单随换歌刷新。
        playbackService.eventBus.subscribe { [weak tray] event in
            if case .trackStarted = event { tray?.refresh() }
        }
        // Settings 切换桌面开关 → 重新同步。
        NotificationCenter.default.addObserver(forName: .musesDesktopFlagsChanged, object: nil,
                                                queue: .main) { [weak hotkeys, weak tray,
                                                                  weak desktopLyrics,
                                                                  weak playback, weak lib] _ in
            Task { @MainActor in
                hotkeys?.sync()
                tray?.setEnabled(UserDefaults.standard.bool(forKey: PrefKey.ffTray))
                if let playback, let lib {
                    desktopLyrics?.setEnabled(
                        UserDefaults.standard.bool(forKey: PrefKey.ffDesktopLyrics),
                        playback: playback, library: lib, lyrics: lyricsSvc)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .musesToggleDesktopLyrics, object: nil,
                                                queue: .main) { [weak desktopLyrics,
                                                                  weak playback, weak lib] _ in
            Task { @MainActor in
                let on = !UserDefaults.standard.bool(forKey: PrefKey.ffDesktopLyrics)
                UserDefaults.standard.set(on, forKey: PrefKey.ffDesktopLyrics)
                if let playback, let lib {
                    desktopLyrics?.setEnabled(on, playback: playback,
                                               library: lib, lyrics: lyricsSvc)
                }
            }
        }

        // Repair / artist backfill / enrichment are library-wide walks. Keep
        // them off the init path so the first window can appear.
        let deferredImport = importService
        let deferredCatalog = youTubeCatalogService
        Task { @MainActor in
            deferredImport.repairYouTubeLibrary()
            deferredCatalog.rebuildFromTrackMetadata()
        }

        // Keychain tokens survive launch, while the account snapshot does not.
        // Rehydrate it only after composition is complete; refresh is
        // best-effort and never blocks the window or playback startup.
        if youTubeAccount.isConnected {
            Task { @MainActor [weak youTubeAccount] in
                await youTubeAccount?.refreshPersistedConnectionIfNeeded()
            }
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
                    .environment(\.ytDlpBridge, ytDlpBridge)
                    .environment(updateService)
                    .environment(commandRegistry)
                    .environment(runtimeCapabilities)
                    .environment(historyService)
                    .environment(contextService)
                    .environment(automationService)
                    .environment(sessionService)
                    .environment(inboxService)
                    .environment(notesService)
                    .environment(focusService)
                    .environment(audioDeviceService)
                    .environment(homeDiscoveryService)
                    .environment(webHomeSessionController)
                    .environment(situationalRecommendationService)
                    .environment(youTubeAccountService)
                    .environment(youTubePlaylistSyncService)
                    .environment(youTubeCatalogService)
                    .environment(\.libraryStoreFallback, usedInMemoryFallback)
                    .modelContainer(modelContainer)
                    .background(MiniPlayerOpener())
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
        // Keep the main scene on SwiftUI's standard window style. The
        // idempotent AppKit bridge makes the titlebar transparent and extends
        // content beneath it without letting scene updates replace the native
        // traffic-light cluster.
        .defaultSize(width: 1280, height: 800)
        Window(tr("Search Muses", "搜索 Muses"), id: SearchWindowPolicy.sceneID) {
            ThemeApplier {
                SearchWindowRoot()
                    .environment(libraryService)
                    .environment(playbackService)
                    .environment(importService)
                    .environment(searchService)
                    .environment(playlistService)
                    .environment(sleepTimer)
                    .environment(globalSearchService)
                    .environment(lyricsService)
                    .environment(\.ytDlpBridge, ytDlpBridge)
                    .environment(updateService)
                    .environment(commandRegistry)
                    .environment(runtimeCapabilities)
                    .environment(historyService)
                    .environment(contextService)
                    .environment(automationService)
                    .environment(sessionService)
                    .environment(inboxService)
                    .environment(notesService)
                    .environment(focusService)
                    .environment(audioDeviceService)
                    .environment(homeDiscoveryService)
                    .environment(webHomeSessionController)
                    .environment(situationalRecommendationService)
                    .environment(youTubeAccountService)
                    .environment(youTubePlaylistSyncService)
                    .environment(youTubeCatalogService)
                    .modelContainer(modelContainer)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(
            width: SearchWindowPolicy.defaultWidth,
            height: SearchWindowPolicy.defaultHeight
        )
        // Phase 24 — 迷你播放器场景(独立 WindowGroup,按需 openWindow(id:))。共享同一 PlaybackService,无第二引擎。
        WindowGroup("MiniPlayer", id: "mini-player") {
            ThemeApplier {
                MiniPlayerView()
                    .environment(libraryService)
                    .environment(playbackService)
                    .environment(focusService)
                    .environment(audioDeviceService)
                    .modelContainer(modelContainer)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 240, height: 380)
        .commands {
            // 替换系统 About:弹出标准 About 面板(读 Info.plist 版本)
            CommandGroup(replacing: .appInfo) {
                Button(tr("About Muses", "关于 Muses")) {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(tr("Settings…", "设置…")) {
                    NotificationCenter.default.post(name: .musesOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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

                // 专注模式(Phase 25):弹 FocusView 面板(经通知,由 RootView 呈现 sheet)。
                Divider()
                Button(tr("Focus Mode", "专注模式")) {
                    NotificationCenter.default.post(name: .musesToggleFocusMode, object: nil)
                }
                if focusService.isActive {
                    Text("\(tr("Focus", "专注")):\(focusService.remainingFormatted)")
                }

                // 音频信息(Phase 26 Audio Nerd Mode):弹 AudioInfoPanel(经通知 → RootView sheet)。
                Divider()
                Button(tr("Audio Info", "音频信息")) {
                    NotificationCenter.default.post(name: .musesToggleAudioInfo, object: nil)
                }
            }
        }
    }
}

/// 监听 `.musesOpenMiniPlayer` 通知,经 `@Environment(\.openWindow)` 打开迷你播放器场景。
/// 受 `ffMiniPlayer` 开关约束:关闭时忽略,绝不强行开窗(Final Spec §15)。
private struct MiniPlayerOpener: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.ffMiniPlayer) private var miniEnabled = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .musesOpenMiniPlayer)) { _ in
                guard miniEnabled else { return }
                openWindow(id: "mini-player")
            }
    }
}
