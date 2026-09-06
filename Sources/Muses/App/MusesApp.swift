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
    // Home dynamic discovery: provider abstraction + cache-first + per-section failure.
    let homeDiscoveryService: HomeDiscoveryService
    /// Optional, isolated YouTube Music Web Home control plane. It is
    /// build-gated, user-consented, and never participates in playback.
    let webHomeSessionController: WebHomeSessionController
    // Situational recommendations for the New tab: deterministic scoring over History/Context/Sessions/Focus/Inbox/Library.
    let situationalRecommendationService: SituationalRecommendationService
    // YouTube account (real Google OAuth 2.0 PKCE + Data API): feeds Home personalization
    // signals (subscribed channels / liked videos → artist names). Credentials and tokens live
    // in the Keychain with a minimal read-only scope; never blocks playback.
    let youTubeAccountService: YouTubeAccountService
    let youTubePlaylistSyncService: YouTubePlaylistSyncService
    let youTubeCatalogService: YouTubeCatalogService
    // Native desktop integration: global hotkeys / menu bar tray / desktop lyrics / mini player.
    let globalHotkeyService: GlobalHotkeyService
    let trayController: TrayController
    let desktopLyricsController: DesktopLyricsController
    private let nowPlayingManager: NowPlayingManager
    private let spotlightIndexer: SpotlightIndexer

    init() {
        MusesSingleInstance.yieldIfOtherInstanceRunning()
        // Brand wordmark font: register early so the first screen's "Muses" wordmark already uses MonteCarlo.
        FontLoader.registerMonteCarlo()
        YTCookieSource.migrateChromeIfNeeded()
        // In-app feature flags enabled by default (the user opted into "enable all").
        // Registers only keys not explicitly set: anything the user turned off in Settings
        // stays off (their choice is never reverted).
        // Global hotkeys / mini player / desktop lyrics remain off by default; the menu bar icon is on.
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
        let ytdlpBridge = YTDlpBridge()
        self.ytDlpBridge = ytdlpBridge
        let catalogService = YouTubeCatalogService(modelContainer: container, bridge: ytdlpBridge)
        self.youTubeCatalogService = catalogService
        Task { @MainActor in
            catalogService.rebuildFromTrackMetadata()
        }
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
        // Notes & bookmarks: read/write entry point for TrackNote/TrackBookmark.
        // No event bus subscription (notes stay decoupled from playback events); with ffNotes off, writes are no-ops.
        self.notesService = NotesService(modelContainer: container)
        self.globalSearchService = GlobalSearchService(
            library: library, catalog: catalogService,
            youTubeSearch: searchService, notes: notesService)
        self.lyricsService = LyricsService(modelContainer: container)
        self.nowPlayingManager = NowPlayingManager(playbackService, library: library, queue: queue)
        // Contextual listening: ffContext is on by default, best-effort capturing local time,
        // output device, and headphone heuristics. The frontmost app bundle id still requires
        // an explicit contextTrackActiveApp opt-in.
        // Never records window titles/URLs/contents. When the flag is off, capture() returns nil and HistoryService stores nil.
        let contextService = ContextService()
        self.contextService = contextService
        // Listening history: subscribes to playbackService.eventBus and writes a ListeningEvent per event.
        // contextProvider is injected so ListeningEvent.contextSummaryJSON gets filled when the event terminates.
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
        // Focus mode: subscription-free, holds the live state; links back to the current ListeningSession (read-only).
        // ffFocusMode is on by default; with no session started, isActive stays false and never suppresses discovery surfaces.
        self.focusService = FocusService(modelContainer: container,
                                         eventBus: playbackService.eventBus,
                                         playback: playbackService,
                                         sessionService: sessionService)
        // Audio output devices: Core Audio enumeration/switching (best-effort), with a 2s poll detecting default-device changes.
        let audioDevices = AudioDeviceService(eventBus: playbackService.eventBus)
        self.audioDeviceService = audioDevices
        Task { @MainActor in audioDevices.startPolling() }
        // Inbox: subscribes to the event bus (.trackStarted→listening) and maintains InboxItem rows;
        // at launch, expired snoozes are restored to unheard. ffInbox is on by default.
        self.inboxService = InboxService(modelContainer: container,
                                         eventBus: playbackService.eventBus)
        inboxService.restoreDueSnoozes()
        // Context automation: subscribes to the event bus and matches AutomationRule triggers/conditions/actions.
        // ffAutomation is on by default. Action handlers wire into library/inbox/playback.
        self.automationService = AutomationService(
            modelContainer: container,
            eventBus: playbackService.eventBus,
            contextProvider: { [weak contextService] in contextService?.capture() },
            actionHandler: AutomationService.makeDefaultActionHandler(
                library: library, inbox: inboxService, playback: playbackService))
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // Index into Spotlight asynchronously after launch.
        Task { @MainActor in indexer.indexAll() }

        // Home dynamic discovery service: the default provider runs themed yt-dlp ytsearch,
        // injected via the searchService.search closure (which calls the @MainActor YTDlpBridge inside).
        // ffDiscovery is on by default; when off, load() is a no-op and HomeView falls back to the existing behavior.
        // Note: an escaping closure in a struct init cannot capture a not-fully-initialized self, hence the local bindings.
        let ytSearchSvc = searchService
        let ytBridge = ytdlpBridge
        let discoveryProvider = YTDlpDiscoveryProvider(
            fetchPlaylist: { url in try await ytBridge.fetchPlaylist(url: url) },
            search: { query, limit in try await ytSearchSvc.search(query: query, limit: limit) }
        )
        // YouTube account service: Google OAuth 2.0 PKCE + YouTube Data API.
        // OAuth client configuration is held by the app build and tokens live in the macOS
        // Keychain; the user only authorizes in the default browser. OAuth never blocks
        // guest browsing, imports, or playback.
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
        // Situational recommendations for the New tab (reads only History/Context/Focus/Inbox/Library + imported YouTube).
        // ffSituationalNew is on by default; when off, compute() returns empty and NewView falls back to RecommendationService.
        self.situationalRecommendationService = SituationalRecommendationService(
            library: library,
            historyService: historyService,
            contextService: contextService,
            focusService: focusService,
            inboxService: inboxService,
            modelContainer: container)

        // GitHub Release update check (replaces the old Sparkle auto-updater).
        // The `checkForUpdates` preference controls automatic checks; no more than one per 24h.
        let updater = UpdateService()
        self.updateService = updater
        Task { @MainActor in
            // Wait 3s after launch before checking, to avoid competing with first-screen load/indexing.
            try? await Task.sleep(for: .milliseconds(3000))
            await updater.checkIfDue()
        }

        // Command registry: centralizes existing command handling so menu shortcuts and global hotkeys share one handler.
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
        registry.register(CommandRegistry.toggleNowPlaying) {
            NotificationCenter.default.post(name: .musesToggleNowPlaying, object: nil)
        }
        registry.register(CommandRegistry.focusSearch) {
            NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
        }
        self.commandRegistry = registry
        self.runtimeCapabilities = RuntimeCapabilities()

        // Desktop integration services: construction + wiring.
        // Hotkey dispatcher: existing commands go through commandRegistry; desktop-only actions (volume/mini/lyrics/focus/inbox) are called directly.
        // Note: an escaping closure in a struct init cannot capture self, hence local bindings with weak capture lists.
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
            onQuit: { NSApp.terminate(nil) },
            playback: playback,
            audioDevices: audioDevices)
        self.trayController = tray
        let desktopLyrics = DesktopLyricsController()
        self.desktopLyricsController = desktopLyrics

        // Initialize each desktop service per the current switch states; Settings toggle notifications refresh them afterwards.
        Task { @MainActor in
            hotkeys.sync()
            tray.setEnabled(UserDefaults.standard.bool(forKey: PrefKey.ffTray))
            desktopLyrics.setEnabled(
                UserDefaults.standard.bool(forKey: PrefKey.ffDesktopLyrics),
                playback: playback, library: lib, lyrics: lyricsSvc)
        }
        // Tray menu refreshes on track change.
        playbackService.eventBus.subscribe { [weak tray] event in
            if case .trackStarted = event { tray?.refresh() }
        }
        // Settings toggling a desktop switch → re-sync.
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
                        // deep link: muses://play?trackId=<id> — playback invoked by Spotlight / external callers
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
        // Mini player scene (its own WindowGroup, opened on demand via openWindow(id:)). Shares the same PlaybackService — no second engine.
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
            // Replaces the system About: opens the standard About panel (reads the Info.plist version).
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
            // Playback control shortcuts (handled centrally via CommandRegistry; global hotkeys reuse the same handlers)
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

                Button(tr("Now Playing", "正在播放")) {
                    commandRegistry.execute(CommandRegistry.toggleNowPlaying)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(tr("Search", "搜索")) {
                    commandRegistry.execute(CommandRegistry.focusSearch)
                }
                .keyboardShortcut("f", modifiers: .command)

                // Sleep timer
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

                // Focus mode: opens the FocusView panel (via notification; RootView presents it as a sheet).
                Divider()
                Button(tr("Focus Mode", "专注模式")) {
                    NotificationCenter.default.post(name: .musesToggleFocusMode, object: nil)
                }
                if focusService.isActive {
                    Text("\(tr("Focus", "专注")):\(focusService.remainingFormatted)")
                }

                // Audio info (Audio Nerd Mode): opens the AudioInfoPanel (via notification → RootView sheet).
                Divider()
                Button(tr("Audio Info", "音频信息")) {
                    NotificationCenter.default.post(name: .musesToggleAudioInfo, object: nil)
                }
            }
        }
    }
}

/// Listens for the `.musesOpenMiniPlayer` notification and opens the mini player scene via `@Environment(\.openWindow)`.
/// Gated by the `ffMiniPlayer` flag: ignored when off; never force-opens a window (Final Spec §15).
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
