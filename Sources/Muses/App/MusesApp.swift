import SwiftUI
import SwiftData
import AppKit

@main
struct MusesApp: App {
    @NSApplicationDelegateAdaptor(MusesAppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer
    /// True when the on-disk library could not be opened and the session is empty in-memory.
    let usedInMemoryFallback: Bool
    let libraryService: LibraryService
    let externalPlaybackRouter: ExternalPlaybackRouter
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
    let sessionService: SessionService
    let notesService: NotesService
    let audioDeviceService: AudioDeviceService
    // Home dynamic discovery: provider abstraction + cache-first + per-section failure.
    let homeDiscoveryService: HomeDiscoveryService
    /// Optional, isolated YouTube Music Web Home control plane. It is
    /// build-gated, user-consented, and never participates in playback.
    let webHomeSessionController: WebHomeSessionController
    // Situational recommendations for the New tab: deterministic scoring over History/Context/Sessions/Library.
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
        _ = L10n.traditionalStrings
        // Music windows are not document-tabbed; this also removes Show Tab Bar /
        // Show All Tabs from View (no CommandGroupPlacement exists for those items).
        NSWindow.allowsAutomaticWindowTabbing = false
        // Brand wordmark font: register early so the first screen's "Muses" wordmark already uses MonteCarlo.
        FontLoader.registerMonteCarlo()
        YTCookieSource.migrateChromeIfNeeded()
        // In-app feature flags enabled by default (the user opted into "enable all").
        // Registers only keys not explicitly set: anything the user turned off in Settings
        // stays off (their choice is never reverted).
        // Global hotkeys / mini player / desktop lyrics remain off by default; the menu bar icon is on.
        UserDefaults.standard.register(defaults: FeatureFlagDefaults.enabledByDefault)
        UserDefaults.standard.register(defaults: WebHomePreferenceDefaults.values)
        UserDefaults.standard.register(defaults: AppearancePreferenceDefaults.values)
        #if DEBUG
        let storeLoad: MusesStoreLoadResult
        // Validation bundles stay isolated even when Finder relaunches them without environment flags.
        if Bundle.main.bundleIdentifier == "com.muses.validation"
            || ProcessInfo.processInfo.environment["MUSES_IN_MEMORY_STORE"] == "1" {
            // An explicit disposable fixture enables disk-migration UI tests.
            // Relaunching without the flag always returns to an in-memory store.
            let fixture = ProcessInfo.processInfo.environment["MUSES_VALIDATION_STORE"]
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            if let fixture, (fixture.path.hasPrefix("/private/tmp/") || fixture.path.hasPrefix("/tmp/")),
               fixture.lastPathComponent == "migration-ui-fixture.sqlite",
               FileManager.default.fileExists(atPath: fixture.path),
               let container = try? makeModelContainer(storeURL: fixture) {
                storeLoad = MusesStoreLoadResult(container: container, usedInMemoryFallback: false)
            } else {
                storeLoad = MusesStoreLoadResult(
                    container: try! makeModelContainer(inMemory: true),
                    usedInMemoryFallback: false
                )
            }
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
        let activeEQ = UserDefaults.standard.string(forKey: PrefKey.eqActivePresetId) ?? "Flat"
        let recommendationCatalog = PublicMusicCatalogProvider()
        playbackService.recommendationProvider = { videoID in
            try await recommendationCatalog.recommendations(after: videoID)
        }
        let customEQ = (try? container.mainContext.fetch(FetchDescriptor<EQPreset>()))?
            .first { $0.id.uuidString == activeEQ }?.bands
        playbackService.restoreEQSettings(defaults: .standard,
            presetBands: customEQ ?? BuiltinEQPresets.all.first { $0.name == activeEQ }?.bands ?? EQPresets.flat)
        self.importService = YouTubeImportService(bridge: ytdlpBridge,
                                                  modelContainer: container,
                                                  catalog: catalogService)
        self.externalPlaybackRouter = ExternalPlaybackRouter(playback: playbackService, importer: importService, container: container)
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
        // Audio output devices: Core Audio enumeration/switching (best-effort), with a 2s poll detecting default-device changes.
        let audioDevices = AudioDeviceService(eventBus: playbackService.eventBus,
            onUnexpectedDisconnect: { [weak playbackService] in playbackService?.pause() })
        self.audioDeviceService = audioDevices
        Task { @MainActor in audioDevices.startPolling() }
        let indexer = SpotlightIndexer(modelContainer: container)
        self.spotlightIndexer = indexer
        // Index into Spotlight asynchronously after launch.
        Task { @MainActor in indexer.indexAll() }

        // Public discovery reads source endpoints without substituting keyword search.
        // Unavailable official content remains an explicit failure.
        // Note: an escaping closure in a struct init cannot capture a not-fully-initialized self, hence the local bindings.
        let ytBridge = ytdlpBridge
        let discoveryProvider = YTDlpDiscoveryProvider(
            fetchPlaylist: { url in try await ytBridge.fetchPlaylist(url: url) }
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
        // Situational recommendations for the New tab (reads only History/Context/Library + imported YouTube).
        // ffSituationalNew is on by default; when off, compute() returns empty and NewView falls back to RecommendationService.
        self.situationalRecommendationService = SituationalRecommendationService(
            library: library,
            historyService: historyService,
            contextService: contextService)

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
        registry.register(CommandRegistry.togglePlayback, handler: { [weak playbackService] in
            playbackService?.toggle()
        }, enabled: { [weak playbackService] in playbackService?.transportState.track != nil })
        registry.register(CommandRegistry.next, handler: { [weak playbackService] in
            playbackService?.next()
        }, enabled: { [weak playbackService] in playbackService?.transportState.track != nil })
        registry.register(CommandRegistry.previous, handler: { [weak playbackService] in
            playbackService?.previous()
        }, enabled: { [weak playbackService] in playbackService?.transportState.track != nil })
        registry.register(CommandRegistry.likeCurrent, handler: { [weak playbackService, weak library] in
            guard let id = playbackService?.state.track?.id else { return }
            library?.toggleLike(id: id)
        }, enabled: { [weak playbackService] in playbackService?.transportState.track != nil })
        registry.register(CommandRegistry.toggleQueue) {
            NotificationCenter.default.post(name: .musesToggleQueue, object: nil)
        }
        registry.register(CommandRegistry.toggleNowPlaying, handler: {
            NotificationCenter.default.post(name: .musesToggleNowPlaying, object: nil)
        }, enabled: { [weak playbackService] in playbackService?.transportState.track != nil })
        registry.register(CommandRegistry.focusSearch) {
            NotificationCenter.default.post(name: .musesFocusSearch, object: nil)
        }
        self.commandRegistry = registry

        // Desktop integration services: construction + wiring.
        // Hotkey dispatcher: existing commands go through commandRegistry; desktop-only actions (volume/mini/lyrics) are called directly.
        // Note: an escaping closure in a struct init cannot capture self, hence local bindings with weak capture lists.
        let playback = playbackService
        let lib = library
        let lyricsSvc = lyricsService
        GlobalHotkeyService.sharedDispatcher = { [weak registry, weak playback] action in
            switch action {
            case GlobalHotkeyService.actionPlayPause, GlobalHotkeyService.actionNext,
                 GlobalHotkeyService.actionPrevious, GlobalHotkeyService.actionLike:
                registry?.execute(action)
            case GlobalHotkeyService.actionVolumeUp:
                playback?.setVolume(min(1, (playback?.volume ?? 0.8) + 0.05))
            case GlobalHotkeyService.actionVolumeDown:
                playback?.setVolume(max(0, (playback?.volume ?? 0.8) - 0.05))
            case GlobalHotkeyService.actionMute:
                playback?.toggleMute()
            case GlobalHotkeyService.actionShowHidePlayer:
                MusesSingleInstance.orderFrontMainWindow()
            case GlobalHotkeyService.actionShowMiniPlayer:
                NotificationCenter.default.post(name: .musesOpenMiniPlayer, object: nil)
            case GlobalHotkeyService.actionShowLyrics:
                NotificationCenter.default.post(name: .musesToggleDesktopLyrics, object: nil)
            default: break
            }
        }
        let hotkeys = GlobalHotkeyService(
            enabledProvider: { UserDefaults.standard.bool(forKey: PrefKey.ffGlobalHotkeys) },
            shortcutProvider: { GlobalHotkeyService.loadShortcuts() },
            dispatcher: { GlobalHotkeyService.sharedDispatcher?($0) })
        self.globalHotkeyService = hotkeys
        self.runtimeCapabilities = RuntimeCapabilities(playback: playbackService, hotkeys: hotkeys, devices: audioDevices)

        let tray = TrayController(
            trackProvider: { [weak playback] in playback?.state.track },
            isPlayingProvider: { [weak playback] in playback?.transportState.isPlaying ?? false },
            onPlayPause: { [weak registry] in registry?.execute(CommandRegistry.togglePlayback) },
            onNext: { [weak registry] in registry?.execute(CommandRegistry.next) },
            onPrevious: { [weak registry] in registry?.execute(CommandRegistry.previous) },
            onLike: { [weak registry] in registry?.execute(CommandRegistry.likeCurrent) },
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

        // Rebuild catalog caches after composition. Historical identities are
        // never backfilled or merged during startup.
        let deferredCatalog = youTubeCatalogService
        Task { @MainActor in
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
        WindowGroup(id: MusesSingleInstance.mainSceneID) {
            ThemeApplier {
                RootView()
                    .onAppear {
                        appDelegate.playback = playbackService
                        if #available(macOS 15.0, *) {
                            MusesAppShortcuts.updateAppShortcutParameters()
                        }
                    }
                    .environment(libraryService)
                    .environment(playbackService)
                    .environment(externalPlaybackRouter)
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
                    .environment(sessionService)
                    .environment(notesService)
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
                        externalPlaybackRouter.open(url)
                    }
            }
        }
        // Keep the main scene on SwiftUI's standard window style. The
        // idempotent AppKit bridge makes the titlebar transparent and extends
        // content beneath it without letting scene updates replace the native
        // traffic-light cluster.
        .windowToolbarStyle(.unified)
        .defaultSize(
            width: WindowChromeMetrics.defaultWidth,
            height: WindowChromeMetrics.defaultHeight
        )
        .commands {
            MusesAppCommands(commandRegistry: commandRegistry, sleepTimer: sleepTimer)
        }
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
                    .environment(sessionService)
                    .environment(notesService)
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
                    .environment(audioDeviceService)
                    .modelContainer(modelContainer)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 240, height: 380)


    }
}

/// App menu, File, View, and Playback. Settings… / ⌘, open the integrated main-window destination.
private struct MusesAppCommands: Commands {
    let commandRegistry: CommandRegistry
    let sleepTimer: SleepTimerService
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.sidebarCollapsed) private var isSidebarCollapsed = false
    @AppStorage(PrefKey.ffMiniPlayer) private var miniEnabled = false
    @AppStorage(PrefKey.language) private var languageRaw = AppLanguage.system.rawValue

    var body: some Commands {
        let _ = languageRaw
        CommandGroup(replacing: .appSettings) {
            Button(tr("Settings…", "设置…", zhHant: "設定…")) {
                MusesSingleInstance.requestSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            Button(tr("About Muses", "关于 Muses")) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(tr("Main Window", "主窗口", zhHant: "主視窗")) {
                if !MusesSingleInstance.orderFrontMainWindow() {
                    openWindow(id: MusesSingleInstance.mainSceneID)
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button(tr("New MiniPlayer Window", "新建迷你播放器窗口")) {
                NotificationCenter.default.post(name: .musesOpenMiniPlayer, object: nil)
            }
            .disabled(!miniEnabled)

            Button(tr("Search", "搜索")) {
                commandRegistry.execute(CommandRegistry.focusSearch)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(replacing: .sidebar) {
            Button(isSidebarCollapsed
                   ? tr("Show Sidebar", "显示边栏")
                   : tr("Hide Sidebar", "隐藏边栏")) {
                isSidebarCollapsed.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            Button(SidebarSection.home.title) { navigate(.home) }
            Button(SidebarSection.new.title) { navigate(.new) }
            Button(SidebarSection.songs.title) { navigate(.songs) }
            Button(SidebarSection.albums.title) { navigate(.albums) }
            Button(SidebarSection.artists.title) { navigate(.artists) }
            Button(SidebarSection.liked.title) { navigate(.liked) }
            Button(SidebarSection.musicVideos.title) { navigate(.musicVideos) }
            Button(SidebarSection.subscriptions.title) { navigate(.subscriptions) }
            Button(SidebarSection.history.title) { navigate(.history) }
            Button(SidebarSection.playlists.title) { navigate(.playlists) }
        }

        CommandMenu(tr("Playback", "播放")) {
            Button(tr("Play/Pause", "播放/暂停")) {
                commandRegistry.execute(CommandRegistry.togglePlayback)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!playbackCommandEnabled(CommandRegistry.togglePlayback))

            Button(tr("Previous", "上一首")) {
                commandRegistry.execute(CommandRegistry.previous)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!playbackCommandEnabled(CommandRegistry.previous))

            Button(tr("Next", "下一首")) {
                commandRegistry.execute(CommandRegistry.next)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!playbackCommandEnabled(CommandRegistry.next))

            Divider()

            Button(tr("Like Current Song", "收藏当前歌曲")) {
                commandRegistry.execute(CommandRegistry.likeCurrent)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!playbackCommandEnabled(CommandRegistry.likeCurrent))

            Button(tr("Toggle Queue", "切换队列")) {
                commandRegistry.execute(CommandRegistry.toggleQueue)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!ContentKeyboardScope.acceptsShortcuts)

            Button(tr("Now Playing", "正在播放")) {
                commandRegistry.execute(CommandRegistry.toggleNowPlaying)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!playbackCommandEnabled(CommandRegistry.toggleNowPlaying))

            Button(tr("Lyrics", "歌词")) {
                NotificationCenter.default.post(name: .musesToggleLyrics, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!playbackCommandEnabled(CommandRegistry.togglePlayback))

            Button(tr("Watch YouTube Video", "观看 YouTube 视频")) {
                NotificationCenter.default.post(name: .musesShowYouTubeVideo, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!playbackCommandEnabled(CommandRegistry.togglePlayback))

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

            Divider()

            Button(tr("Audio Info", "音频信息")) {
                NotificationCenter.default.post(name: .musesToggleAudioInfo, object: nil)
            }
        }

        CommandGroup(replacing: .help) {
            Button(tr("Muses Help", "Muses 帮助")) {
                NSWorkspace.shared.open(MenuBarPolicy.helpDocumentationURL)
            }
        }
    }

    private func navigate(_ section: SidebarSection) {
        NotificationCenter.default.post(
            name: .musesNavigateFromSearch,
            object: GlobalSearchRoute.section(section)
        )
    }

    private func playbackCommandEnabled(_ command: String) -> Bool {
        ContentKeyboardScope.acceptsShortcuts && commandRegistry.isEnabled(command)
    }
}

/// Listens for the `.musesOpenMiniPlayer` notification and opens the mini player scene via `@Environment(\.openWindow)`.
/// Gated by the `ffMiniPlayer` flag: ignored when off; never force-opens a window (Final Spec §15).
private struct MiniPlayerOpener: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.ffMiniPlayer) private var miniEnabled = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                // OpenWindowAction belongs to the scene, not a retained RootView.
                // Keep this route available after the last browse window closes.
                MusesSingleInstance.createMainWindow = { openWindow(id: MusesSingleInstance.mainSceneID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .musesOpenMiniPlayer)) { _ in
                guard miniEnabled else { return }
                openWindow(id: "mini-player")
            }
    }
}
