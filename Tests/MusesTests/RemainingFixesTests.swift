import Testing
import Foundation
import SwiftData
import AppKit
@testable import Muses

@MainActor
struct RemainingFixesTests {

    @Test("player position adds segment start to node time")
    func playerPositionMath() {
        #expect(PlayerPosition.seconds(segmentStart: 12, playerSampleTime: 44100, playerSampleRate: 44100) == 13)
        #expect(PlayerPosition.seconds(segmentStart: 5, playerSampleTime: 0, playerSampleRate: 48000) == 5)
    }

    @Test("stream URL cache keys include quality")
    func streamCacheQualityKey() {
        let cache = StreamURLCache(defaultTTL: 3600)
        let hi = URL(string: "https://example.com/hi.m4a")!
        let lo = URL(string: "https://example.com/lo.m4a")!
        cache.set(videoId: "vid", url: hi, quality: "bestaudio")
        cache.set(videoId: "vid", url: lo, quality: "64k")
        #expect(cache.get(videoId: "vid", quality: "bestaudio") == hi)
        #expect(cache.get(videoId: "vid", quality: "64k") == lo)
    }

    @Test("shuffle keeps locked rows in place")
    func shufflePreservesLocked() {
        let q = QueueService()
        let ctx = (0..<5).map { i in
            TrackSnapshot(id: UUID(), title: "t\(i)", artist: "a", albumTitle: nil,
                          durationSeconds: 1, youTubeId: "test-video",
                          artworkUrl: nil, sampleRate: nil,
                          bitDepth: nil, codec: nil, isLossless: false)
        }
        q.play(ctx[2], context: ctx, from: .album)
        q.toggleLocked(itemId: q.items[0].id)
        q.toggleLocked(itemId: q.items[4].id)
        let lockedFirst = q.items[0].id
        let lockedLast = q.items[4].id
        q.toggleShuffle()
        #expect(q.items.first?.id == lockedFirst)
        #expect(q.items.last?.id == lockedLast)
        #expect(q.current()?.track.title == "t2")
    }

    @Test("priority insert sorts upNext so peekNext is highest")
    func priorityOrdersUpNext() {
        let q = QueueService()
        let a = TrackSnapshot(id: UUID(), title: "low", artist: "a", albumTitle: nil,
                              durationSeconds: 1, youTubeId: "test-video",
                              artworkUrl: nil, sampleRate: nil,
                              bitDepth: nil, codec: nil, isLossless: false)
        let b = TrackSnapshot(id: UUID(), title: "high", artist: "a", albumTitle: nil,
                              durationSeconds: 1, youTubeId: "test-video",
                              artworkUrl: nil, sampleRate: nil,
                              bitDepth: nil, codec: nil, isLossless: false)
        q.play(a, context: [a], from: .album)
        q.addToQueue(a)
        q.addToQueueWithPriority(b)
        #expect(q.peekNext()?.track.title == "high")
    }

    @Test("replacement lock does not wipe the collection")
    func replacementLockKeepsQueue() {
        let q = QueueService()
        let ctx = [
            TrackSnapshot(id: UUID(), title: "a", artist: "a", albumTitle: nil,
                          durationSeconds: 1, youTubeId: "test-video",
                          artworkUrl: nil, sampleRate: nil,
                          bitDepth: nil, codec: nil, isLossless: false),
            TrackSnapshot(id: UUID(), title: "b", artist: "a", albumTitle: nil,
                          durationSeconds: 1, youTubeId: "test-video",
                          artworkUrl: nil, sampleRate: nil,
                          bitDepth: nil, codec: nil, isLossless: false)
        ]
        q.play(ctx[0], context: ctx, from: .album)
        q.replacementLocked = true
        let outsider = TrackSnapshot(id: UUID(), title: "x", artist: "a", albumTitle: nil,
                                     durationSeconds: 1, youTubeId: "test-video",
                                     artworkUrl: nil, sampleRate: nil,
                                     bitDepth: nil, codec: nil, isLossless: false)
        q.play(outsider, context: [outsider], from: .search)
        #expect(q.items.count == 2)
        #expect(q.items.map(\.track.title) == ["a", "b"])
        #expect(q.upNext.first?.track.title == "x")
    }

    @Test("Google Desktop loopback redirect is detected")
    func oauthLoopbackDetection() {
        let loop = GoogleOAuthConfig(clientID: "id", clientSecret: "s",
                                     redirectURI: "http://127.0.0.1:53682/",
                                     scopes: GoogleOAuthConfig.defaultScopes)
        #expect(loop.isLoopbackRedirect)
        #expect(loop.loopbackPort == 53682)
        let custom = GoogleOAuthConfig(clientID: "id", clientSecret: "s",
                                       redirectURI: "muses:/oauth",
                                       scopes: GoogleOAuthConfig.defaultScopes)
        #expect(!custom.isLoopbackRedirect)
    }

    @Test("shared discovery failure detects cookie and quota errors")
    func sharedDiscoveryFailure() {
        #expect(YouTubeIdentity.isSharedDiscoveryFailure(
            "yt-dlp exit code 1: could not find chrome cookies database"))
        #expect(YouTubeIdentity.isSharedDiscoveryFailure("HTTP Error 429"))
        #expect(!YouTubeIdentity.isSharedDiscoveryFailure("parse failed: line 2"))
    }

    @Test("YouTube identity distinguishes account from playback cookies")
    func youtubeIdentityCopy() {
        #expect(YouTubeIdentity.sidebarSubtitle(
            oauthConnected: true, channelTitle: "Streetwise", cookieSource: .chrome)
            == "Streetwise")
        let cookie = YouTubeIdentity.sidebarSubtitle(
            oauthConnected: false, channelTitle: nil, cookieSource: .chrome)
        #expect(cookie == tr("Not connected", "未连接"))
        #expect(!cookie.localizedCaseInsensitiveContains("sign-in"))
        #expect(YouTubeIdentity.sidebarSubtitle(
            oauthConnected: false, channelTitle: nil, cookieSource: .none)
            == tr("Not connected", "未连接"))
        #expect(YouTubePlaylistID.isMusicAlbum("OLAK5uy_abc"))
        #expect(!YouTubePlaylistID.isMusicAlbum("PLreuse"))
        let hint = YouTubeIdentity.discoveryCookieHint(cookieSource: .none)
        #expect(hint.localizedCaseInsensitiveContains("cookie"))
    }

    @Test("YouTube embed HTML uses nocookie host and the video id")
    func youtubeEmbedHTML() {
        let html = YouTubeEmbed.pageHTML(videoId: "LQeq2F1D2dE")
        #expect(html.contains("youtube-nocookie.com/embed/LQeq2F1D2dE"))
        #expect(html.contains("autoplay=1"))
        #expect(!YouTubeEmbed.pageHTML(videoId: "ab<script>").contains("<script>"))
        #expect(YouTubeEmbed.isVideo(TrackSnapshot(
            id: UUID(), title: "t", artist: "a", albumTitle: nil, durationSeconds: 1,
            youTubeId: "abc", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)))
        #expect(!YouTubeEmbed.isVideo(nil))
    }

    @Test("single instance yields when another pid is live")
    func singleInstanceYield() {
        #expect(MusesSingleInstance.shouldYield(otherPids: [10, 20], currentPid: 10))
        #expect(!MusesSingleInstance.shouldYield(otherPids: [10], currentPid: 10))
        #expect(!MusesSingleInstance.shouldYield(otherPids: [], currentPid: 1))
    }

    @Test("builtin EQ resolver returns Flat and HiFi")
    func eqResolverBuiltins() throws {
        let container = try makeModelContainer(inMemory: true)
        #expect(BuiltinEQPresets.bands(forStoredId: "Flat", container: container)
            == EQPresets.flat)
        #expect(BuiltinEQPresets.bands(forStoredId: "HiFi", container: container)
            != EQPresets.flat)
    }

    @Test("chrome cookie source is kept")
    func migrateChromeCookies() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: PrefKey.ytCookieSource)
        defaults.set(YTCookieSource.chrome.rawValue, forKey: PrefKey.ytCookieSource)
        YTCookieSource.migrateChromeIfNeeded()
        #expect(defaults.string(forKey: PrefKey.ytCookieSource) == YTCookieSource.chrome.rawValue)
        if let previous {
            defaults.set(previous, forKey: PrefKey.ytCookieSource)
        } else {
            defaults.removeObject(forKey: PrefKey.ytCookieSource)
        }
    }

    @Test("settings cookie cases include chrome")
    func settingsIncludesChrome() {
        #expect(YTCookieSource.settingsCases.contains(.chrome))
        #expect(YTCookieSource.settingsCases.contains(.none))
        #expect(YTCookieSource.settingsCases.contains(.safari))
        #expect(YTCookieSource.settingsCases.contains(.firefox))
        #expect(YTCookieSource.settingsCases.contains(.file))
    }

    @Test("repeat cycles off → one → all")
    func repeatCycleOrder() {
        #expect(RepeatMode.off.next == .one)
        #expect(RepeatMode.one.next == .all)
        #expect(RepeatMode.all.next == .off)
    }

    @Test("OAuth defaults to YouTube read-only")
    func oauthDefaultScopeIsReadOnly() {
        #expect(GoogleOAuthConfig.defaultScopes == [GoogleOAuthConfig.readOnlyScope])
        #expect(!GoogleOAuthConfig.defaultScopes.contains(GoogleOAuthConfig.manageScope))
    }

    @Test("resume-after-video preference key exists")
    func resumeAfterVideoPrefKey() {
        #expect(PrefKey.resumeAfterVideo == "muses.playback.resumeAfterVideo")
    }

    @Test("tray template knocks out the paper background")
    func trayTemplateImage() {
        let statusIcon = TrayIcon.templateImage()
        #expect(statusIcon.isTemplate)
        #expect(TrayIcon.symbolName == "music.note")
        #expect(TrayIcon.symbolPointSize == 15)

        let src = NSImage(size: NSSize(width: 32, height: 32))
        src.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 16, height: 16)).fill()
        src.unlockFocus()
        let img = TrayIcon.templateImage(from: src, pointSize: 18)
        #expect(img.isTemplate)
        #expect(img.size == NSSize(width: 18, height: 18))
        #expect(img.representations.contains { $0.pixelsWide == 36 && $0.size.width == 18 })
    }
}
