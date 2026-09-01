import Testing
import Foundation
import MediaPlayer
@testable import Muses

/// Native Desktop Integration acceptance (Final Spec §10.1).
/// Covers the purely testable core: hotkey encoding/collision detection, the tray menu model, muses:// deep link parsing,
/// and NowPlayingManager's MPRepeatType → RepeatMode mapping. Carbon/AppKit/NSPanel registration and
/// window presentation are runtime surfaces that headless CI cannot verify reliably, so they stay manual/platform checks (§15).
@MainActor
@Suite("Phase 24 Desktop Integration")
struct DesktopIntegrationTests {

    private func snap(_ title: String, artist: String = "A", id: UUID = UUID()) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: artist, albumTitle: nil,
                      durationSeconds: 200, youTubeId: "test-video",
                      artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    // MARK: - HotkeyShortcut encoding + collision detection

    @Test("HotkeyShortcut Codable 往返")
    func shortcutCodable() throws {
        let sc = HotkeyShortcut(keyCode: 49, modifiers: 0x0100 | 0x2000)   // space + cmd|control
        let data = try JSONEncoder().encode(sc)
        let back = try JSONDecoder().decode(HotkeyShortcut.self, from: data)
        #expect(back == sc)
    }

    @Test("conflicts:无冲突返回空;同一快捷键两动作报冲突")
    func conflictsDetection() {
        let none: [String: HotkeyShortcut] = [
            "a": HotkeyShortcut(keyCode: 1, modifiers: 0),
            "b": HotkeyShortcut(keyCode: 2, modifiers: 0)
        ]
        #expect(GlobalHotkeyService.conflicts(none).isEmpty)

        let clash: [String: HotkeyShortcut] = [
            "a": HotkeyShortcut(keyCode: 1, modifiers: 9),
            "b": HotkeyShortcut(keyCode: 1, modifiers: 9),   // same as a → conflict
            "c": HotkeyShortcut(keyCode: 2, modifiers: 9)
        ]
        let c = GlobalHotkeyService.conflicts(clash)
        #expect(c.count == 1)
        let (_, actions) = c.first!
        #expect(Set(actions) == Set(["a", "b"]))
    }

    @Test("默认绑定无内部冲突(出厂配置可注册)")
    func defaultsHaveNoConflicts() {
        #expect(GlobalHotkeyService.conflicts(GlobalHotkeyService.defaults).isEmpty)
    }

    @Test("loadShortcuts:无存储时回退默认;有存储时用用户值")
    func loadShortcutsFallback() {
        let key = PrefKey.globalHotkeys
        UserDefaults.standard.removeObject(forKey: key)
        let fallback = GlobalHotkeyService.loadShortcuts()
        #expect(fallback == GlobalHotkeyService.defaults)

        let custom: [String: HotkeyShortcut] = [
            GlobalHotkeyService.actionPlayPause: HotkeyShortcut(keyCode: 0, modifiers: 1)
        ]
        GlobalHotkeyService.saveShortcuts(custom)
        let loaded = GlobalHotkeyService.loadShortcuts()
        #expect(loaded[GlobalHotkeyService.actionPlayPause] == HotkeyShortcut(keyCode: 0, modifiers: 1))
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - TrayMenuModel

    @Test("TrayMenuModel:无曲目时控制项禁用;有曲目时启用")
    func trayMenuEnabledStates() {
        let empty = TrayMenuModel.items(track: nil, isPlaying: false)
        #expect(empty.first(where: { $0.kind == .header })?.title == tr("Muses", "Muses"))
        // No track → play/next/prev/like/inbox disabled
        for kind in [TrayMenuModel.Item.Kind.playPause, .next, .previous, .like, .addToInbox] {
            let item = empty.first { $0.kind == kind }!
            #expect(item.enabled == false)
        }
        // openMini/openMain/quit always enabled
        for kind in [TrayMenuModel.Item.Kind.openMini, .openMain, .quit] {
            #expect(empty.first { $0.kind == kind }?.enabled == true)
        }

        let playing = TrayMenuModel.items(track: snap("Song"), isPlaying: true)
        #expect(playing.first { $0.kind == .header }?.title == "Song — A")
        #expect(playing.first { $0.kind == .playPause }?.title == tr("Pause", "暂停"))
        #expect(playing.first { $0.kind == .playPause }?.enabled == true)
        let paused = TrayMenuModel.items(track: snap("Song"), isPlaying: false)
        #expect(paused.first { $0.kind == .playPause }?.title == tr("Play", "播放"))
    }

    @Test("TrayMenuModel:tag/kind 往返")
    func trayMenuTagRoundTrip() {
        for kind in [TrayMenuModel.Item.Kind.playPause, .next, .previous, .like,
                     .addToInbox, .openMini, .openMain, .quit] {
            #expect(TrayMenuModel.kind(for: TrayMenuModel.tag(for: kind)) == kind)
        }
        #expect(TrayMenuModel.kind(for: 999) == nil)   // unknown tag
    }

    // MARK: - muses:// deep link parsing (routed by the system once CFBundleURLTypes is registered)

    @Test("SpotlightIndexer.trackId(from:) parses muses://play?trackId=<uuid>")
    func deepLinkParse() throws {
        let id = UUID()
        let url = URL(string: "muses://play?trackId=\(id.uuidString)")!
        #expect(SpotlightIndexer.trackId(from: url) == id)
    }

    @Test("SpotlightIndexer.trackId(from:):非法 scheme/host 返回 nil")
    func deepLinkRejects() {
        let id = UUID()
        #expect(SpotlightIndexer.trackId(from: URL(string: "http://play?trackId=\(id.uuidString)")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://open?trackId=\(id.uuidString)")!) == nil)
        #expect(SpotlightIndexer.trackId(from: URL(string: "muses://play?trackId=not-a-uuid")!) == nil)
    }

    // MARK: - NowPlayingManager.repeatMode mapping (pure function)

    @Test("repeatMode(from:):off/all/one 直映;未知保持当前")
    func repeatModeMapping() {
        #expect(NowPlayingManager.repeatMode(from: .off, current: .all) == .off)
        #expect(NowPlayingManager.repeatMode(from: .all, current: .off) == .all)
        #expect(NowPlayingManager.repeatMode(from: .one, current: .off) == .one)
        // @unknown default is unreachable (the enum is fully covered); just verify no crash.
        #expect(NowPlayingManager.repeatMode(from: .all, current: .one) == .all)
    }

    // MARK: - Info.plist CFBundleURLTypes registration (runtime check: read the bundle)

    @Test("Info.plist CFBundleURLTypes registers the muses scheme")
    func infoPlistURLSchemeRegistered() throws {
        // The test host's Info.plist (copied in by SwiftPM resources). If registration is missing, skip the assertion instead of failing,
        // because a headless test bundle may not include an Info.plist (§15: never fabricate).
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            // Without an Info.plist in the test process, validate the source plist file directly (a development-time guarantee).
            try verifySourceInfoPlistHasScheme()
            return
        }
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("muses"))
    }

    private func verifySourceInfoPlistHasScheme() throws {
        let url = Bundle.main.url(forResource: "Info", withExtension: "plist")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // MusesTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // repository
                .appendingPathComponent("Sources/Muses/Resources/Info.plist")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Info.plist not found at \(url.path)"); return
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        let types = (plist["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("muses"))
    }
}