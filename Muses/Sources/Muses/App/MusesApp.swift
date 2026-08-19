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
    let contextService: ContextService
    let automationService: AutomationService
    let sessionService: SessionService
    let inboxService: InboxService
    let notesService: NotesService
    let focusService: FocusService
    let audioDeviceService: AudioDeviceService
    // Phase D3 — Home 动态发现:provider 抽象 + cache-first + per-section failure。
    let homeDiscoveryService: HomeDiscoveryService
    // Phase D5 — New 情境化推荐:History/Context/Sessions/Focus/Inbox/Library 确定性打分。
    let situationalRecommendationService: SituationalRecommendationService
    // P2 — YouTube 账户(真实 Google OAuth 2.0 PKCE + Data API):用于 Home 个性化信号
    // (订阅频道/喜欢的视频→艺术家名),凭证与令牌存 Keychain,最小只读 scope,永不阻断播放。
    let youTubeAccountService: YouTubeAccountService
    // P3 — 非持久化元数据富集投影层:统一 local + YouTube-derived 专辑/艺术家浏览;
    // MusicBrainz 确认 + Cover Art 封面,不改 SwiftData schema。
    let metadataEnrichmentService: MetadataEnrichmentService
    // Phase 24 — 原生桌面集成:全局热键 / 菜单栏托盘 / 桌面歌词 / 迷你播放器。
    let globalHotkeyService: GlobalHotkeyService
    let trayController: TrayController
    let desktopLyricsController: DesktopLyricsController
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        // 品牌字标字体:尽早注册,使首屏 "Muses" wordmark 即用 MonteCarlo。
        FontLoader.registerMonteCarlo()
        // P5 issue #7 — 应用内功能标志默认开启(用户显式选择「全部启用」)。
        // 仅注册未显式设置的键:用户曾在设置中关闭的项保持关闭(不回退其选择)。
        // 桌面集成 4 项(全局热键/托盘/迷你播放器/桌面歌词)仍默认关——占用系统资源、
        // 不打扰;可在设置中按需开启。
        UserDefaults.standard.register(defaults: FeatureFlagDefaults.enabledByDefault)
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
        self.nowPlayingManager = NowPlayingManager(playbackService, library: library, queue: queue)
        // 上下文监听(Phase 23 §10.2):opt-in(ffContext 默认关),best-effort 捕获本地时间/
        // 前台应用 bundle id(需 contextTrackActiveApp 再显式开启)/输出设备/耳机启发式。
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
        // 收听会话 + 崩溃恢复(Phase 18):订阅事件总线,维护 ListeningSession 行 +
        // 周期 checkpoint 到 QueueState 崩溃恢复槽;构造时检测可恢复会话供 RootView 弹对话框。
        // 须在 queue.restore() 之后构造(已在上方执行),以读取恢复的 currentTrackId/位置。
        self.sessionService = SessionService(modelContainer: container,
                                             eventBus: playbackService.eventBus,
                                             playback: playbackService,
                                             queue: queue)
        // 专注模式(Phase 25 §10.9):订阅无关,持运行态;关联回当前 ListeningSession(只读)。
        // ffFocusMode 默认关 → start 为 no-op,isActive 保持 false,不抑制发现表面。
        self.focusService = FocusService(modelContainer: container,
                                         eventBus: playbackService.eventBus,
                                         playback: playbackService,
                                         sessionService: sessionService)
        // 音频输出设备(Phase 26 §10.10):Core Audio 枚举/切换(best-effort),2s 轮询检测默认变更。
        let audioDevices = AudioDeviceService(eventBus: playbackService.eventBus)
        self.audioDeviceService = audioDevices
        Task { @MainActor in audioDevices.startPolling() }
        // 收件箱(Phase 20):订阅事件总线(.trackStarted→listening),维护 InboxItem 行;
        // 启动时把到期 snooze 还原为 unheard。功能开关 ffInbox 默认关 → add 为 no-op。
        self.inboxService = InboxService(modelContainer: container,
                                         eventBus: playbackService.eventBus)
        inboxService.restoreDueSnoozes()
        // 上下文自动化(Phase 23 §12):订阅事件总线,匹配 AutomationRule 触发器/条件/动作。
        // ffAutomation 默认关 → handle 直接返回。动作处理器接入 library/inbox/playback。
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
        // ffDiscovery 默认关 → load() no-op,HomeView 回退现有行为。
        // 注:struct init 中 escaping 闭包不可捕获未完全初始化的 self,故用本地绑定。
        let ytSearchSvc = searchService
        let discoveryProvider = YTDlpDiscoveryProvider { query, limit in
            try await ytSearchSvc.search(query: query, limit: limit)
        }
        // P2 — YouTube 账户服务:Google OAuth 2.0 PKCE + YouTube Data API v3。
        // 凭证(Client ID/Secret/Redirect URI)与令牌均存 macOS Keychain;
        // 最小只读 scope(youtube.readonly);OAuth 仅用于个性化信号,永不阻断播放。
        // 用户需在设置中填入自己的 Google Cloud OAuth 凭证(产品不内置)。
        let youTubeAccount = YouTubeAccountService()
        self.youTubeAccountService = youTubeAccount
        // P3 — 非持久化浏览投影 + 富集服务(只读 ModelContainer,off-main 构建)。
        self.metadataEnrichmentService = MetadataEnrichmentService(container: container)
        self.homeDiscoveryService = HomeDiscoveryService(
            provider: discoveryProvider,
            library: library,
            historyService: historyService,
            youTubeSignals: { [weak youTubeAccount] in
                await youTubeAccount?.signals()
            })
        // Phase D5 — New 情境化推荐(只读 History/Context/Focus/Inbox/Library + 已导入 YouTube)。
        // ffSituationalNew 默认关 → compute() 返回空,NewView 回退 RecommendationService。
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
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title.isEmpty || $0.frameAutosaveName == "MusesMainWindow" }?
                    .makeKeyAndOrderFront(nil)
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
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
                    .environment(contextService)
                    .environment(automationService)
                    .environment(sessionService)
                    .environment(inboxService)
                    .environment(notesService)
                    .environment(focusService)
                    .environment(audioDeviceService)
                    .environment(homeDiscoveryService)
                    .environment(situationalRecommendationService)
                    .environment(youTubeAccountService)
                    .environment(metadataEnrichmentService)
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
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
