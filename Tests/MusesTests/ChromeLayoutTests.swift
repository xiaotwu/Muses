import Testing
import AppKit
import Foundation
@testable import Muses

@MainActor
struct ChromeLayoutTests {

    @Test("YouTube hqdefault URLs are treated as letterboxed")
    func letterboxURLDetection() {
        let hq = URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")!
        let mq = URL(string: "https://i.ytimg.com/vi/abc/mqdefault.jpg")!
        let max = URL(string: "https://i.ytimg.com/vi/abc/maxresdefault.jpg")!
        #expect(YouTubeThumbnail.isLetterboxed(hq))
        #expect(!YouTubeThumbnail.isLetterboxed(mq))
        #expect(!YouTubeThumbnail.isLetterboxed(max))
        #expect(YouTubeThumbnail.urlString(videoId: "abc") == "https://i.ytimg.com/vi/abc/hqdefault.jpg")
    }

    @Test("4:3 YouTube thumbs drop the 12.5% letterbox bars")
    func cropsFourByThreeLetterbox() {
        let image = makeSolidImage(width: 480, height: 360)
        let cropped = YouTubeThumbnail.cropLetterboxIfNeeded(
            image,
            url: URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")
        )
        guard let cg = cropped.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("cropped image has no CGImage")
            return
        }
        #expect(cg.width == 480)
        #expect(cg.height == 270)
    }

    @Test("16:9 thumbs are left unchanged")
    func leavesSixteenByNine() {
        let image = makeSolidImage(width: 320, height: 180)
        let result = YouTubeThumbnail.cropLetterboxIfNeeded(
            image,
            url: URL(string: "https://i.ytimg.com/vi/abc/mqdefault.jpg")
        )
        guard let cg = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("result has no CGImage")
            return
        }
        #expect(cg.width == 320)
        #expect(cg.height == 180)
    }

    @Test("Monochrome dark accent is FAFAFC")
    func appleMusicKeyColor() {
        #expect(AppleMusicTokens.keyColorHex == "FAFAFC")
        #expect(abs(AppleMusicTokens.keyColorRGB.r - 250.0 / 255.0) < 0.0001)
        #expect(abs(AppleMusicTokens.keyColorRGB.g - 250.0 / 255.0) < 0.0001)
        #expect(abs(AppleMusicTokens.keyColorRGB.b - 252.0 / 255.0) < 0.0001)
    }

    @Test("dark page background is measured AM Web 1F1F1F")
    func darkPageBackground() {
        #expect(abs(AppleMusicTokens.darkPageRGB.r - 31.0 / 255.0) < 0.0001)
        #expect(AppleMusicTokens.pageTitleSize == 34)
        #expect(AppleMusicTokens.sectionTitleSize == 22)
        #expect(AppleMusicTokens.sidebarWidth >= 232 && AppleMusicTokens.sidebarWidth <= 260)
        #expect(AppleMusicTokens.cardCorner == 12)
        #expect(AppleMusicTokens.editorialWidth == 540)
        #expect(AppleMusicTokens.editorialHeight == 309)
    }

    @Test("library sidebar is permanently expanded")
    func sidebarIsPermanent() {
        #expect(LibraryChromePolicy.sidebarIsPermanent)
    }

    @Test("selected chrome glyph uses accent and no glow")
    func selectedGlyphIsAccentWithoutGlow() {
        #expect(ChromeGlyphStyle.selectedGlowRadius == 5)
        #expect(ChromeGlyphStyle.selectedUsesAccent)
    }

    @Test("search is one independent floating glass window")
    func searchWindowContract() {
        #expect(SearchChromePolicy.topResult(from: ["Alpha", "Alpine", "Beta"], query: "alp") == "Alpha")
        #expect(SearchChromePolicy.presentsAsFloatingGlass)
        #expect(SearchChromePolicy.panelMaxWidth == 680)
        #expect(SearchChromePolicy.panelCorner == 18)
        #expect(SearchChromePolicy.addMusicSystemImage == "plus")
        #expect(SearchWindowPolicy.sceneID == "search")
        #expect(SearchWindowPolicy.isSingleInstance)
        #expect(SearchWindowPolicy.closesOnEscape)
        #expect(SearchWindowPolicy.defaultWidth == 680)
        #expect(SearchWindowPolicy.defaultHeight == 620)
        #expect(SearchWindowPolicy.minimumWidth == 600)
        #expect(SearchWindowPolicy.minimumHeight == 520)
        #expect(SearchWindowPolicy.screenEdgeInset == 32)
        #expect(SearchWindowPolicy.draggableHeaderHeight == 52)
        #expect(SearchWindowPolicy.contentInset == 24)
        #expect(SearchWindowPolicy.controlHeight == 44)
        #expect(SearchWindowPolicy.sourceSegmentHeight == 34)
        #expect(SearchWindowPolicy.resultRowHeight == 68)
    }

    @Test("dock lyrics stays in the dock while artwork owns Now Playing entry")
    func dockLyricsPolicy() {
        #expect(DockLyricsPolicy.action(nowPlayingOpen: false) == .toggleDrawer)
        #expect(DockLyricsPolicy.action(nowPlayingOpen: true) == .toggleLyricsFocus)
    }

    @Test("Top Picks prefers hero then mixed then recent, max three unique")
    func topPicksResolver() {
        func yt(_ id: String) -> DiscoveryItem {
            .youTube(YouTubeDiscoveryCard(id: id, title: id))
        }
        let picks = TopPicksResolver.picks(
            hero: yt("h"),
            mixed: [yt("h"), yt("m1"), yt("m2")],
            recent: [yt("m1"), yt("r1")],
            max: 3
        )
        #expect(picks.map(\.id) == ["yt:h", "yt:m1", "yt:m2"])
    }

    @Test("Top Picks does not fabricate cards")
    func topPicksSparse() {
        let picks = TopPicksResolver.picks(hero: nil, mixed: [], recent: [
            .youTube(YouTubeDiscoveryCard(id: "only", title: "only"))
        ], max: 3)
        #expect(picks.count == 1)
    }

    @Test("New featured slot is the first available item")
    func newFeaturedSlot() {
        let items = [
            DiscoveryItem.youTube(YouTubeDiscoveryCard(id: "a", title: "A")),
            DiscoveryItem.youTube(YouTubeDiscoveryCard(id: "b", title: "B"))
        ]
        #expect(NewFeaturedResolver.featured(from: items)?.id == "yt:a")
        #expect(NewFeaturedResolver.featured(from: []) == nil)
    }

    @Test("Home and New keep distinct Apple Music page templates")
    func discoveryPageTemplates() {
        #expect(HomePagePolicy.topPicksUsePortraitCards)
        #expect(HomePagePolicy.additionalShelvesUseSquareCards)
        #expect(NewPagePolicy.featuredUsesLandscapeEditorialCards)
        #expect(NewPagePolicy.bestNewSongsUsesAdaptiveMatrix)
        #expect(NewPagePolicy.compactSongColumnMinimum == 280)
    }

    @Test("Settings account lives in the YouTube pane, not a browse overlay")
    func settingsAccountLivesInYouTubePane() {
        #expect(SettingsChromePolicy.accountLivesInYouTubePane)
        #expect(!SettingsChromePolicy.showsAccount(isPresented: true))
        #expect(!SettingsChromePolicy.showsAccount(isPresented: false))
    }

    @Test("Apple Music Web shell is left nav plus floating capsule")
    func liveWebShell() {
        #expect(AppleMusicChrome.primaryNavInSidebar)
        #expect(AppleMusicChrome.playerIsFloatingCapsule)
        #expect(AppleMusicChrome.selectedNavUsesAccent)
        #expect(AppleMusicTokens.editorialWidth == 540)
    }

    @Test("live AM Web spacing tokens")
    func liveSpacingTokens() {
        #expect(AppleMusicTokens.sidebarInset == 8)
        #expect(AppleMusicTokens.sidebarWidth == 244)
        #expect(AppleMusicTokens.playerBottomMargin == 20)
        #expect(AppleMusicTokens.playerHorizontalMargin == 16)
        #expect(AppleMusicTokens.editorialWidth == 540)
        #expect(AppleMusicTokens.editorialHeight == 309)
        #expect(AppleMusicTokens.contentPaddingX == 40)
        #expect(AppleMusicSpacing.pageHorizontal == AppleMusicTokens.contentPaddingX)
        #expect(AppleMusicSpacing.pageTop == 18)
        #expect(AppleMusicSpacing.browseTitleTop == 32)
        #expect(AppleMusicSpacing.headerToPrimary == 28)
        #expect(AppleMusicSpacing.related == 20)
        #expect(AppleMusicSpacing.section > AppleMusicSpacing.shelfContent)
        #expect(AppleMusicTokens.navItemHeight == 34)
        #expect(AppleMusicTokens.capsuleWidth == 668)
        #expect(AppleMusicTokens.collectionDeckRoomyFooterHeight > 0)
        #expect(AppleMusicTokens.collectionDeckRoomyCardWidth
                < AppleMusicTokens.collectionDeckRoomyCardWidth
                    + AppleMusicTokens.collectionDeckRoomyFooterHeight)
        #expect(AppleMusicTokens.collectionDeckCompactBreakpoint
                < AppleMusicTokens.collectionDeckWideBreakpoint)
        #expect(AppleMusicTokens.collectionDeckHandleHeight >= 44)
    }

    @Test("player capsule overlays content and does not reserve a row")
    func playerOverlaysContent() {
        #expect(PlayerLayoutPolicy.isWindowOverlay)
        #expect(PlayerTransportPolicy.leadingClusterIsTransport)
        #expect(PlayerTransportPolicy.identityIsCentered)
        #expect(PlayerControlPolicy.usesSingleVolumeEntry)
        #expect(PlayerControlPolicy.usesYouTubeMark)
        #expect(PlayerControlPolicy.hidesExpandControl)
        #expect(PlayerControlPolicy.nowPlayingOpensFromArtwork)
        #expect(PlayerIdlePolicy.showsTransport(hasTrack: false))
        #expect(PlayerIdlePolicy.showsTransport(hasTrack: true))
        #expect(PlayerIdlePolicy.showsLyrics(hasTrack: false))
        #expect(PlayerIdlePolicy.showsVolume(hasTrack: false))
        #expect(PlayerIdlePolicy.showsYouTube(hasTrack: false))
        #expect(PlayerIdlePolicy.showsProgress(hasTrack: false))
        #expect(PlayerIdlePolicy.showsQueue(hasTrack: false))
        #expect(PlayerIdlePolicy.showsIdentityMark(hasTrack: false))
        #expect(!PlayerIdlePolicy.showsIdentityMark(hasTrack: true))
        let minimumDetailWidth = WindowChromeMetrics.minimumWidth
            - AppleMusicTokens.sidebarWidth
            - WindowChromeMetrics.sidebarOuterInset
        #expect(AppleMusicTokens.capsuleWidth > minimumDetailWidth)
        #expect(minimumDetailWidth - 2 * AppleMusicTokens.playerHorizontalMargin > 0)
        #expect(ProductionPlaybackPolicy.isYouTubeOnly)
    }

    @Test("queue is an integrated opaque trailing pane")
    func queueChrome() {
        #expect(QueueChromePolicy.isIntegratedTrailingPane)
        #expect(!QueueChromePolicy.isDetachedRoundedCard)
        #expect(QueueChromePolicy.width == 360)
    }

    @Test("Now Playing covers the window and hides the dock")
    func nowPlayingFullscreenChrome() {
        #expect(NowPlayingChromePolicy.coversWindow)
        #expect(NowPlayingChromePolicy.hidesDock)
        #expect(NowPlayingChromePolicy.canOpen(hasTrack: true))
        #expect(!NowPlayingChromePolicy.canOpen(hasTrack: false))
    }

    @Test("Now Playing keeps keyboard input in its own window")
    func nowPlayingKeyboardInputStaysInWindow() {
        #expect(NowPlayingInputPolicy.acceptsGlobalKeyEvents(nowPlayingPresented: true))
        #expect(!NowPlayingInputPolicy.acceptsGlobalKeyEvents(nowPlayingPresented: false))
        #expect(NowPlayingPresentationPolicy.dismissDuration == 0.30)
        #expect(NowPlayingPresentationPolicy.acceptsInteraction(isPresented: true))
        #expect(!NowPlayingPresentationPolicy.acceptsInteraction(isPresented: false))
        #expect(NowPlayingPresentationPolicy.isAccessibilityVisible(isPresented: true))
        #expect(!NowPlayingPresentationPolicy.isAccessibilityVisible(isPresented: false))
    }

    @Test("Now Playing matches the roomy reference and adapts at minimum width")
    func nowPlayingReferenceGeometry() {
        let playing = NowPlayingLayout.resolve(width: 1_440, height: 900, isPlaying: true)
        let paused = NowPlayingLayout.resolve(width: 1_440, height: 900, isPlaying: false)
        let reducedMotionPlaying = NowPlayingLayout.resolve(
            width: 1_440,
            height: 900,
            isPlaying: true,
            reduceMotion: true
        )
        let medium = NowPlayingLayout.resolve(width: 1_228, height: 768, isPlaying: true)
        let compact = NowPlayingLayout.resolve(
            width: WindowChromeMetrics.minimumWidth,
            height: WindowChromeMetrics.minimumHeight,
            isPlaying: true
        )

        #expect(playing.presentation == .split)
        #expect(playing.contentWidth == 1_240)
        #expect(playing.stageSide == 404)
        #expect(abs(playing.renderedArtworkSide - playing.stageSide) < 0.001)
        #expect(playing.artworkScale == NowPlayingLayout.liveCoverPlayingScale)
        #expect(reducedMotionPlaying.artworkScale == 1)
        #expect(reducedMotionPlaying.artworkSlotSide == reducedMotionPlaying.stageSide)
        #expect(reducedMotionPlaying.renderedArtworkSide == reducedMotionPlaying.stageSide)
        #expect(abs(paused.renderedArtworkSide - playing.renderedArtworkSide) < 0.001)
        #expect(paused.artworkSlotSide == playing.artworkSlotSide)
        #expect(playing.columnGap == 144)
        #expect(playing.lyricsLeadingInset == 30)
        #expect(medium.presentation == .split)
        #expect(medium.contentWidth == 1_068)
        #expect(compact.presentation == .stacked)
        #expect(compact.contentWidth == 792)
        #expect(compact.stageSide <= 360)
        #expect(NowPlayingLayout.edgeInset == 22)
        #expect(NowPlayingLayout.topChromeHeight
                == NowPlayingLayout.edgeInset + NowPlayingLayout.topControlHeight)
        #expect(NowPlayingLayout.leadingControlInset
                == WindowChromeMetrics.trafficLightClearanceWidth
                    + NowPlayingLayout.trafficLightControlGap)
        #expect(NowPlayingLayout.trafficLightControlGap == NowPlayingLayout.edgeInset)
        #expect(NowPlayingLayout.mirroredOuterControlInset
                == NowPlayingLayout.leadingControlInset)
        #expect(NowPlayingLayout.vinylVerticalOffset == -12)
    }

    @Test("Now Playing output menu excludes input and aggregate devices")
    func nowPlayingOutputDevicePolicy() {
        let devices = [
            AudioDeviceService.AudioDevice(
                id: 1,
                name: "MacBook Pro Microphone",
                channels: 0
            ),
            AudioDeviceService.AudioDevice(
                id: 2,
                name: "MacBook Pro Speakers",
                channels: 2
            ),
            AudioDeviceService.AudioDevice(
                id: 3,
                name: "CADefaultDeviceAggregate-73745-0",
                channels: 2
            ),
            AudioDeviceService.AudioDevice(
                id: 4,
                name: "Studio Aggregate Device",
                channels: 8
            ),
            AudioDeviceService.AudioDevice(
                id: 5,
                name: "USB DAC",
                channels: 2
            ),
            AudioDeviceService.AudioDevice(
                id: 6,
                name: "USB DAC",
                channels: 2
            )
        ]

        let visible = NowPlayingOutputDevicePolicy.visibleDevices(devices)
        #expect(visible.map(\.id) == [2, 5])
        #expect(NowPlayingOutputDevicePolicy.menuLabelWidth >= 160)
        #expect(NowPlayingOutputDevicePolicy.menuLabelWidth <= 190)
    }

    @Test("Now Playing mute restores the last audible volume")
    func nowPlayingVolumePolicy() {
        #expect(NowPlayingVolumePolicy.toggledVolume(current: 0.65, remembered: 0.4) == 0)
        #expect(NowPlayingVolumePolicy.toggledVolume(current: 0, remembered: 0.65) == 0.65)
        #expect(NowPlayingVolumePolicy.toggledVolume(current: 0, remembered: 0)
                == NowPlayingVolumePolicy.fallbackAudibleVolume)
        #expect(NowPlayingVolumePolicy.rememberedAudibleVolume(
            current: 0,
            previous: 0.65
        ) == 0.65)
        #expect(NowPlayingVolumePolicy.rememberedAudibleVolume(
            current: 0.3,
            previous: 0.65
        ) == 0.3)
    }

    @Test("Now Playing atmosphere removes bright neutrals and caps palette brightness")
    func nowPlayingAtmospherePalette() {
        let cyan = NSColor(srgbRed: 0.18, green: 0.82, blue: 1, alpha: 1)
        let palette = ArtworkAtmospherePalette.colors(from: [.white, cyan])
        #expect(palette.count == 1)
        #expect(palette.allSatisfy {
            ArtworkAtmospherePalette.brightness(of: $0)
                <= ArtworkAtmospherePalette.maximumBrightness + 0.001
        })

        let neutralFallback = ArtworkAtmospherePalette.colors(from: [.white])
        #expect(neutralFallback.count == 1)
        #expect(ArtworkAtmospherePalette.brightness(of: neutralFallback[0])
                <= ArtworkAtmospherePalette.maximumBrightness + 0.001)
    }

    @Test("immersive lyrics fade by distance without blurring accessibility fallbacks")
    func immersiveLyricsVisualHierarchy() {
        #expect(LyricsVisualStyle.opacity(
            distance: 0, isCurrent: true, immersive: true, prioritizeLegibility: false
        ) == 1)
        #expect(LyricsVisualStyle.opacity(
            distance: 4, isCurrent: false, immersive: true, prioritizeLegibility: false
        ) < LyricsVisualStyle.opacity(
            distance: 1, isCurrent: false, immersive: true, prioritizeLegibility: false
        ))
        #expect(LyricsVisualStyle.blurRadius(
            distance: 4, isCurrent: false, immersive: true, prioritizeLegibility: false
        ) > 0)
        #expect(LyricsVisualStyle.blurRadius(
            distance: 4, isCurrent: false, immersive: true, prioritizeLegibility: true
        ) == 0)
    }

    @Test("vinyl rotation is elapsed-time based and freezes when inactive")
    func elapsedTimeVinylRotation() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let afterOneSecond = start.addingTimeInterval(1)
        let expected = VinylRotation.degreesPerSecond
        #expect(VinylRotation.secondsPerRevolution == 16)
        #expect(VinylRotation.rpm == 3.75)
        #expect(VinylRotation.degreesPerSecond == 22.5)
        #expect(abs(VinylRotation.angle(
            accumulatedDegrees: 0,
            activeSince: start,
            at: afterOneSecond,
            isRotating: true
        ) - expected) < 0.0001)
        #expect(VinylRotation.angle(
            accumulatedDegrees: 42,
            activeSince: start,
            at: afterOneSecond,
            isRotating: false
        ) == 42)
    }

    @Test("permanent sidebar uses edge-attached liquid glass")
    func permanentSidebarGlass() {
        #expect(SidebarGlassPolicy.usesLiquidGlass)
        #expect(SidebarGlassPolicy.touchesTopLeadingAndBottomEdges)
        #expect(LibraryChromePolicy.sidebarIsPermanent)
        #expect(TrafficLightsPolicy.livesInToolbar)
        #expect(WindowChromeMetrics.sidebarOuterInset == 0)
    }

    @Test("traffic lights stay native-owned and use one stable clearance")
    func nativeTrafficLightPolicy() {
        #expect(!TrafficLightsPolicy.reparentsStandardButtons)
        #expect(!TrafficLightsPolicy.usesDelayedLayoutRetries)
        #expect(WindowChromeMetrics.trafficLightClearanceWidth == 72)
        #expect(WindowChromeMetrics.trafficLightClearanceHeight == 28)
        #expect(WindowChromeMetrics.trafficLightTopInset == 0)
        #expect(WindowChromeMetrics.minimumWidth == 840)
        #expect(WindowChromeMetrics.minimumHeight == 600)
    }

    @Test("main window configuration preserves native traffic light ownership")
    func mainWindowConfigurationPreservesTrafficLightOwners() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Songs"
        window.subtitle = "Library"
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        let ownersBefore = buttons.compactMap { $0.superview.map(ObjectIdentifier.init) }

        #expect(buttons.count == 3)
        #expect(ownersBefore.count == 3)

        MusesSingleInstance.configureMainWindow(window)

        let ownersAfter = buttons.compactMap { $0.superview.map(ObjectIdentifier.init) }
        #expect(ownersAfter == ownersBefore)
        #expect(buttons.allSatisfy { !$0.isHidden })
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Muses")
        #expect(window.subtitle.isEmpty)
        #expect(window.contentMinSize == NSSize(
            width: WindowChromeMetrics.minimumWidth,
            height: WindowChromeMetrics.minimumHeight
        ))
    }

    @Test("main-window lookup rejects Search and Mini Player windows")
    func exactMainWindowLookup() {
        let main = NSWindow()
        let search = NSWindow()
        let mini = NSWindow()
        search.identifier = NSUserInterfaceItemIdentifier("Muses.search-window")
        search.setFrameAutosaveName("MusesSearchWindow")
        mini.identifier = NSUserInterfaceItemIdentifier("mini-player")

        MusesSingleInstance.configureMainWindow(main)

        #expect(MusesSingleInstance.isMainWindow(main))
        #expect(!MusesSingleInstance.isMainWindow(search))
        #expect(!MusesSingleInstance.isMainWindow(mini))
        #expect(MusesSingleInstance.mainWindow(in: [search, mini, main]) === main)
        // Scene restoration may replace both public strings after attachment.
        main.identifier = NSUserInterfaceItemIdentifier("restored-scene")
        main.setFrameAutosaveName("restored-frame")
        #expect(MusesSingleInstance.isMainWindow(main))
        #expect(MusesSingleInstance.mainWindow(in: [search, mini, main]) === main)
        #expect(MusesSingleInstance.mainWindow(in: [search, mini]) == nil)
    }

    @Test("station cards clip overflow so hover cannot steal the next cell")
    func stationCardClipsOverflow() {
        #expect(StationCardHitPolicy.clipsOverflow)
    }

    @Test("playlist list never forces height of every row")
    func playlistListIsLazy() {
        #expect(PlaylistListPolicy.minListHeight(rowCount: 500, rowHeight: 56) == nil)
    }

    @Test("All Playlists uses the measured hero-card grid")
    func playlistOverviewHeroMetrics() {
        #expect(PlaylistOverviewMetrics.minimumColumnWidth == 250)
        #expect(PlaylistOverviewMetrics.maximumColumnWidth == 280)
        #expect(PlaylistOverviewMetrics.cardWidth == 260)
        #expect(PlaylistOverviewMetrics.artworkHeight == 230)
        #expect(PlaylistOverviewMetrics.footerHeight == 100)
        #expect(PlaylistOverviewMetrics.cardHeight == 330)
        #expect(PlaylistOverviewMetrics.cornerRadius == 20)
        #expect(PlaylistOverviewMetrics.columnSpacing == 24)
        #expect(PlaylistOverviewMetrics.rowSpacing == 30)
        #expect(PlaylistOverviewMetrics.hoverLift == 5)
        #expect(PlaylistOverviewMetrics.pressedScale == 0.992)
    }

    @Test("sidebar rows use the full row as the hit target")
    func sidebarFullRowHit() {
        #expect(SidebarRowHitPolicy.usesFullRowHitTarget)
    }

    @Test("Settings preserves category redirects in the integrated destination")
    func integratedSettingsCategories() {
        #expect(SettingsChromePolicy.presentsInMainWindow)
        #expect(SettingsCategory.audioQuality.destination == .playback)
        #expect(SettingsCategory.desktop.destination == .appearance)
        #expect(SettingsCategory.updates.destination == .about)
        #expect(Set(SettingsCategory.allCases.map(\.toolbarIcon)).count == SettingsCategory.allCases.count)
    }

    @Test("playlist unavailable Retry reloads through the existing refresh path")
    func playlistUnavailableRetryWiring() throws {
        let source = try readSource("Sources/Muses/Features/Playlist/PlaylistsView.swift")
        let unavailableStart = try #require(source.range(of: "title: tr(\"Playlists unavailable\""))
        let unavailableEnd = try #require(source.range(of: ".padding(16)", range: unavailableStart.upperBound..<source.endIndex))
        let unavailable = source[unavailableStart.lowerBound..<unavailableEnd.lowerBound]
        #expect(unavailable.contains("actionTitle: tr(\"Retry\", \"重试\")"))
        #expect(unavailable.contains("action: refresh"))
        let refreshStart = try #require(source.range(of: "private func refresh()"))
        let refreshEnd = try #require(source.range(of: "private func deletePlaylist", range: refreshStart.upperBound..<source.endIndex))
        #expect(source[refreshStart.lowerBound..<refreshEnd.lowerBound]
            .contains("playlists = playlistService.fetchAll()"))
    }

    @Test("menu bar puts playback in Playback and keeps View for chrome")
    func menuBarPolicy() {
        #expect(MenuBarPolicy.playbackCommandsLiveInPlaybackMenu)
        #expect(MenuBarPolicy.playbackCommandsAreNotInViewMenu)
        #expect(MenuBarPolicy.viewMenuIncludesSidebarToggle)
        #expect(MenuBarPolicy.viewMenuIncludesLibraryDestinations)
        #expect(MenuBarPolicy.fileMenuOmitsDuplicateLibraryWindow)
        #expect(MenuBarPolicy.fileMenuIncludesMiniPlayerWindow)
        #expect(MenuBarPolicy.searchLivesInFileMenu)
        #expect(MenuBarPolicy.searchIsNotInPlaybackMenu)
        #expect(MenuBarPolicy.viewMenuOmitsWindowTabs)
        #expect(MenuBarPolicy.helpOpensProjectDocs)
        #expect(MenuBarPolicy.helpDocumentationURL.host == "xiaotwu.github.io")
    }

    @Test("Settings scene and Playback menu are wired in source")
    func settingsAndMenuSourceContract() throws {
        let app = try readSource("Sources/Muses/App/MusesApp.swift")
        #expect(!app.contains("Settings {"))
        #expect(app.contains("MusesSingleInstance.requestSettings()"))
        #expect(app.contains("CommandMenu(tr(\"Playback\""))
        #expect(app.contains("New MiniPlayer Window"))
        #expect(app.contains("replacing: .newItem"))
        #expect(app.contains("replacing: .sidebar"))
        #expect(app.contains("replacing: .help"))
        #expect(app.contains("allowsAutomaticWindowTabbing = false"))
        #expect(app.contains("WindowChromeMetrics.defaultWidth"))
        #expect(app.contains("WindowChromeMetrics.defaultHeight"))
        #expect(!app.contains("CommandGroup(after: .toolbar)"))
        #expect(app.contains("replacing: .appSettings"))

        let playbackMenu = playbackMenuSource(in: app)
        #expect(playbackMenu.contains("Play/Pause"))
        #expect(playbackMenu.contains("Audio Info"))
        #expect(!playbackMenu.contains("Button(tr(\"Search\""))
        #expect(app.contains("Button(tr(\"Search\""))
        #expect(app.contains("keyboardShortcut(\"f\", modifiers: .command)"))
        #expect(app.contains("MenuBarPolicy.helpDocumentationURL"))

        let root = try readSource("Sources/Muses/App/RootView.swift")
        #expect(!root.contains("SettingsSheet("))
        #expect(root.contains("SettingsPage(path: $settingsPath)"))
        #expect(!root.contains("showSettings"))

        let sidebar = try readSource("Sources/Muses/Features/SidebarView.swift")
        #expect(sidebar.contains("SidebarSection.new.title"))
        #expect(!sidebar.contains("Discover"))
        #expect(sidebar.contains("SidebarNavPolicy.settingsFooterTitle"))
        #expect(sidebar.contains("musesOpenSettings"))

        let settings = try readSource("Sources/Muses/Features/Settings/SettingsSheet.swift")
        #expect(settings.contains("GPUSettingsView()"))
        #expect(SettingsPanePolicy.gpuAccelerationLivesInAppearance)
        #expect(!SettingsPanePolicy.gpuAccelerationLivesInGeneral)
        let appearancePane = settings.range(of: "case .appearance, .desktop:")
        let gpu = settings.range(of: "GPUSettingsView()")
        let generalPane = settings.range(of: "case .general:")
        #expect(appearancePane != nil && gpu != nil && generalPane != nil)
        if let appearancePane, let gpu, let generalPane {
            #expect(gpu.lowerBound > appearancePane.lowerBound)
            #expect(gpu.lowerBound > generalPane.lowerBound)
        }
    }

    private func playbackMenuSource(in app: String) -> String {
        guard let start = app.range(of: "CommandMenu(tr(\"Playback\"") else { return "" }
        let rest = app[start.lowerBound...]
        guard let end = rest.range(of: "CommandGroup(replacing: .help)") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    private func readSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("content layer badges use opaque scrim instead of material")
    func contentLayerAvoidsMaterialBadges() throws {
        #expect(!ContentGlassPolicy.browsingCardsUseGlassEffect)
        #expect(!ContentGlassPolicy.badgesUseMaterial)
        #expect(ContentGlassPolicy.badgesUseOpaqueScrim)
        #expect(!ContentBadgeStyle.usesMaterial)
        #expect(ContentBadgeStyle.usesOpaqueScrim)

        let files = [
            "Sources/Muses/Features/Shared/AlbumObject.swift",
            "Sources/Muses/Features/Shared/CollectionSongDeck.swift",
            "Sources/Muses/Features/Shared/ArtistObject.swift",
            "Sources/Muses/Features/Catalog/CatalogViews.swift",
            "Sources/Muses/Features/HomeView+Sections.swift",
            "Sources/Muses/Features/MiniPlayer/MiniPlayerView.swift"
        ]
        for file in files {
            let source = try readSource(file)
            #expect(!source.contains("ultraThinMaterial"), "\(file) still uses material")
            #expect(!source.contains("glassEffect"), "\(file) still uses glassEffect")
        }

        let album = try readSource("Sources/Muses/Features/Shared/AlbumObject.swift")
        #expect(album.contains("ContentScrimCircle") || album.contains("ContentBadgeStyle.fill"))
        #expect(!album.contains(".musesGlass("))
    }

    @Test("idle player bar preserves transport layout with a template mark")
    func idlePlayerBarSourceContract() throws {
        let source = try readSource("Sources/Muses/Features/PlayerBar.swift")
        #expect(source.contains("PlayerIdlePolicy.showsProgress"))
        #expect(source.contains("idleIdentity"))
        #expect(source.contains("TrayIcon.menuBarImage"))
        #expect(source.contains(".disabled(!hasTrack)"))
        #expect(source.contains("Not Playing"))
        #expect(!source.contains("airplayaudio"))
    }

    @Test("audio output glyph is a speaker, not AirPlay")
    func audioOutputGlyphIsSpeaker() throws {
        #expect(!AudioOutputGlyphPolicy.usesAirPlaySymbol)
        #expect(AudioOutputGlyphPolicy.defaultSystemImage == "speaker.wave.2")
        #expect(AudioOutputGlyphPolicy.systemImage(forDeviceName: nil) == "speaker.wave.2")
        #expect(AudioOutputGlyphPolicy.systemImage(forDeviceName: "MacBook Pro Speakers")
                == "speaker.wave.2")
        #expect(AudioOutputGlyphPolicy.systemImage(forDeviceName: "AirPods Pro") == "headphones")
        #expect(AudioOutputGlyphPolicy.systemImage(forDeviceName: "Living Room AirPlay")
                == "airplayaudio")
        #expect(AudioOutputGlyphPolicy.accessibilityLabel(forDeviceName: "MacBook Pro Speakers")
                == tr("Audio output", "音频输出"))

        let volume = try readSource("Sources/Muses/Features/Shared/LiquidGlassVolumeBar.swift")
        #expect(volume.contains("AudioOutputGlyphPolicy.systemImage"))
        #expect(!volume.contains("Image(systemName: \"airplayaudio\")"))

        let menuBar = try readSource("Sources/Muses/Features/MiniPlayer/MenuBarPlayerView.swift")
        #expect(menuBar.contains("LiquidGlassVolumeBar("))
        #expect(!menuBar.contains("Image(systemName: \"airplayaudio\")"))
    }

    @Test("Listen again uses recents or empty copy, never fabricated cards")
    func listenAgainEmptyContract() {
        #expect(ListenAgainEmptyPolicy.placeholderCardCount(hasRecents: false, isLoading: true) == 0)
        #expect(ListenAgainEmptyPolicy.placeholderCardCount(hasRecents: false, isLoading: false) == 0)
        #expect(ListenAgainEmptyPolicy.placeholderCardCount(hasRecents: true, isLoading: true) == 0)
        #expect(ListenAgainEmptyPolicy.showsEmptyCopy(hasRecents: false))
        #expect(!ListenAgainEmptyPolicy.showsEmptyCopy(hasRecents: true))
        #expect(ListenAgainEmptyPolicy.showsRecentCards(hasRecents: true))
        #expect(!ListenAgainEmptyPolicy.showsRecentCards(hasRecents: false))
        #expect(ListenAgainEmptyPolicy.hidesDiscoverySection(id: "listen-again", title: "Charts"))
        #expect(ListenAgainEmptyPolicy.hidesDiscoverySection(
            id: "web-home-listen", title: "Listen again"))
        #expect(ListenAgainEmptyPolicy.hidesDiscoverySection(
            id: "web-home-listen-zh", title: "再听一次"))
        #expect(!ListenAgainEmptyPolicy.hidesDiscoverySection(id: "charts", title: "Charts"))
    }

    @Test("important empty states expose a next step and hide no-op playback")
    func emptyStateNextStepContract() throws {
        #expect(EmptyStatePolicy.songsEmptyOpensSearch)
        #expect(!EmptyStatePolicy.hidesNoOpPlaybackControls)
        #expect(EmptyStatePolicy.playlistsUnavailableRetries)

        let empty = try readSource("Sources/Muses/Features/Common/EmptyStateView.swift")
        #expect(empty.contains("actionTitle"))
        #expect(empty.contains("action:"))

        let songs = try readSource("Sources/Muses/Features/SongsListView.swift")
        #expect(songs.contains("emptyActionTitle"))
        #expect(songs.contains("musesFocusSearch"))
        #expect(songs.contains("if !rows.isEmpty"))

        let playlists = try readSource("Sources/Muses/Features/Playlist/PlaylistsView.swift")
        #expect(playlists.contains("Playlists unavailable"))
        #expect(playlists.contains("actionTitle: tr(\"Retry\""))
        #expect(playlists.contains("action: refresh"))
    }

    /// Scenario A lock: AppTheme.system + 1280×800 main window. One test (and one
    /// live pass) shares that appearance and geometry. Light, minimum 840×600,
    /// signed-in, or playing are later named rounds — never mixed into this one.
    @Test("scenario A verification lock uses named default geometry")
    func scenarioAVerificationLock() {
        #expect(VerificationLockPolicy.scenarioATheme == .system)
        #expect(AppearancePreferenceDefaults.values[PrefKey.theme] as? String
                == AppTheme.system.rawValue)
        #expect(VerificationLockPolicy.scenarioAWindowWidth == WindowChromeMetrics.defaultWidth)
        #expect(VerificationLockPolicy.scenarioAWindowHeight == WindowChromeMetrics.defaultHeight)
        #expect(WindowChromeMetrics.defaultWidth == 1280)
        #expect(WindowChromeMetrics.defaultHeight == 800)
        #expect(WindowChromeMetrics.minimumWidth == 840)
        #expect(WindowChromeMetrics.minimumHeight == 600)
        #expect(SearchWindowPolicy.defaultWidth == 680)
        #expect(SearchWindowPolicy.defaultHeight == 620)
    }

    @Test("dead runtime capabilities and orphan lyrics flag stay gone")
    func deadCapabilitiesStayGone() throws {
        let caps = try readSource("Sources/Muses/Services/System/RuntimeCapabilities.swift")
        #expect(!caps.contains("weatherContext"))
        #expect(!caps.contains("not implemented"))
        #expect(!caps.contains("func isUsable"))
        #expect(!caps.contains("func explanation"))
        #expect(!caps.contains("wordSyncedLyrics"))
        #expect(!caps.contains("translationLyrics"))
        #expect(!caps.contains("headphoneDetection"))
        #expect(!caps.contains("outputDeviceSwitching"))

        let prefs = try readSource("Sources/Muses/Domain/UserPreferences.swift")
        #expect(!prefs.contains("ffAdvancedLyrics"))
        #expect(!prefs.contains("muses.ff.advancedLyrics"))

        let lyrics = try readSource("Sources/Muses/Features/Settings/LyricsSettingsView.swift")
        #expect(lyrics.contains("original lyrics are never generated from memory"))

        let desktop = try readSource("Sources/Muses/Features/Settings/DesktopSettingsView.swift")
        #expect(desktop.contains("macOS default device"))

        let home = try readSource("Sources/Muses/Features/HomeView+Sections.swift")
        #expect(HomeGuestStatusPolicy.unsignedInShowsSingleCue)
        #expect(HomeGuestStatusPolicy.unsignedInHidesGuestBanner)
        #expect(home.contains("Public discovery"))
        #expect(!home.contains("Make Home yours"))
        #expect(!home.contains("guestBanner"))
        #expect(home.contains("Sign In"))

        let homeView = try readSource("Sources/Muses/Features/HomeView.swift")
        #expect(!homeView.contains("guestBanner"))
    }

    @Test("sidebar New title matches the New page and Settings footer is Settings")
    func sidebarCopyContract() {
        #expect(SidebarNavPolicy.newTitle() == SidebarSection.new.title)
        #expect(SidebarNavPolicy.newTitle() == tr("New", "新发现"))
        #expect(SidebarNavPolicy.settingsFooterTitle() == tr("Settings", "设置"))
        #expect(!SidebarNavPolicy.includesRecently)
        #expect(!SidebarSection.allCases.map(\.rawValue).contains("recently"))
        #expect(AppearancePreferenceDefaults.values[PrefKey.theme] as? String
                == AppTheme.system.rawValue)
    }

    @Test("Unified media destinations coexist without retired chrome entries")
    func removedDestinationsStayAbsent() {
        let destinations = Set(SidebarSection.allCases.map(\.rawValue))
        #expect(!destinations.contains("recently"))
        #expect(destinations.contains("musicVideos"))
        #expect(destinations.contains("subscriptions"))
        #expect(!destinations.contains("radio"))
        #expect(!destinations.contains("inbox"))
    }

    @Test("song station grid is portrait 148–176")
    func songStationGridMetrics() {
        #expect(SongGridMetrics.minCard == 148)
        #expect(SongGridMetrics.maxCard == 176)
        #expect(SongGridMetrics.spacing == 18)
        #expect(abs(SongGridMetrics.aspect - 0.75) < 0.001)
    }

    @Test("YouTube Music catalog URLs are music.youtube.com")
    func youTubeMusicCatalog() {
        #expect(YouTubeMusicCatalog.charts.hasPrefix("https://music.youtube.com/"))
        #expect(YouTubeMusicCatalog.newReleases.hasPrefix("https://music.youtube.com/"))
        #expect(YouTubeMusicCatalog.moods.hasPrefix("https://music.youtube.com/"))
        #expect(YouTubeMusicCatalog.mix(videoId: "abc").contains("RDabc"))
    }

    @Test("personal discovery: empty liked and no subs → no sections")
    func personalDiscoveryEmpty() async {
        let sections = await YouTubePersonalDiscovery.sections(liked: []) { _ in [] }
        #expect(sections.isEmpty)
    }

    @Test("personal discovery: liked plus mix")
    func personalDiscoveryLikedAndMix() async {
        let liked = [YouTubeVideo(id: "yt_sample_1", title: "Song A", channelTitle: "Ch", thumbnailURL: nil)]
        let mix = [YTDlpBridge.YTDlpPlaylistEntry(id: "m1", title: "Mix Song", uploader: "U")]
        let sections = await YouTubePersonalDiscovery.sections(liked: liked) { url in
            #expect(url.contains("RDyt_sample_1"))
            return mix
        }
        #expect(sections.count == 2)
        #expect(sections[0].id == "yt-liked")
        let mixIds = sections[1].items.compactMap { if case .youTube(let c) = $0 { c.id } else { nil } }
        #expect(mixIds == ["m1"])
    }

    @Test("personal discovery: mix failure still returns liked")
    func personalDiscoveryMixFailureKeepsLiked() async {
        let liked = [YouTubeVideo(id: "yt_sample_1", title: "Song A", channelTitle: "Ch", thumbnailURL: nil)]
        let sections = await YouTubePersonalDiscovery.sections(liked: liked) { _ in
            throw NSError(domain: "test", code: 1)
        }
        #expect(sections.map(\.id) == ["yt-liked"])
    }

    @Test("personal discovery: subscriptions search rail")
    func personalDiscoverySubscriptions() async {
        let entries = [YTDlpBridge.YTDlpPlaylistEntry(id: "s1", title: "Sub Song", uploader: "Channel X")]
        let sections = await YouTubePersonalDiscovery.sections(
            liked: [],
            subscriptionTitles: ["Channel X"],
            fetchMix: { _ in [] },
            search: { query in
                #expect(query.contains("Channel X"))
                return entries
            }
        )
        #expect(sections.contains { $0.id == "yt-subs" })
    }

    @Test("Apple Music shell contract")
    func appleMusicShellContract() {
        #expect(PlayerDockMetrics.height == AppleMusicTokens.capsuleHeight)
        #expect(AppleMusicTokens.sidebarWidth == 244)
        #expect(LibraryChromePolicy.sidebarIsPermanent)
        #expect(SearchWindowPolicy.isSingleInstance)
        #expect(DockLyricsPolicy.action(nowPlayingOpen: false) == .toggleDrawer)
        #expect(ChromeGlyphStyle.selectedGlowRadius == 5)
        #expect(AppleMusicTokens.keyColorHex == "FAFAFC")
        #expect(AppleMusicChrome.playerIsFloatingCapsule)
        #expect(AppleMusicChrome.primaryNavInSidebar)
    }

    @Test("player is a floating capsule, not a full-width dock")
    func playerDockMetrics() {
        #expect(PlayerDockMetrics.height == AppleMusicTokens.capsuleHeight)
        #expect(PlayerDockMetrics.art == 40)
        #expect(PlayerDockMetrics.progressHorizontalInset == PlayerDockMetrics.height / 2)
        #expect(PlayerDockMetrics.progressTopInset == 0)
        #expect(PlayerDockMetrics.progressHeight == 3)
        #expect(AppleMusicChrome.playerIsFloatingCapsule)
        #expect(PlayerDockMetrics.play > PlayerDockMetrics.icon)
        #expect(AppTopTab.from(.home) == .home)
        #expect(AppTopTab.from(.new) == .new)
        #expect(AppTopTab.from(.songs) == .library)
        #expect(SidebarSection.home.isLibrary == false)
        #expect(SidebarSection.playlists.isLibrary == true)
    }

    @Test("media cache keys include quality")
    func mediaCacheQualityKey() {
        let dir = MediaFileCache.directory
        #expect(dir.path.contains("Muses/streams"))
        let a = MediaFileCache.file(videoId: "abc", quality: "bestaudio", ext: "m4a")
        let b = MediaFileCache.file(videoId: "abc", quality: "128k", ext: "m4a")
        #expect(a.lastPathComponent.contains("bestaudio"))
        #expect(b.lastPathComponent.contains("128k"))
        #expect(a != b)
    }

    @Test("lyrics titles drop Official Video decorations")
    func sanitizesOfficialVideo() {
        #expect(LyricsService.sanitizedTitle("Letter In Orange (Official Video)") == "Letter In Orange")
        #expect(LyricsService.sanitizedTitle("Song [Official Audio]") == "Song")
        #expect(LyricsService.sanitizedTitle("Plain Title") == "Plain Title")
        #expect(LyricsService.queryTitles("Song (Official Video)") == ["Song (Official Video)", "Song"])
    }

    private func makeSolidImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
