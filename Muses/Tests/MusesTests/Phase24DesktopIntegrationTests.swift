import Testing
import Foundation
import MediaPlayer
@testable import Muses

/// Phase 24 — Native Desktop Integration 验收(Final Spec §10.1)。
/// 覆盖可纯测的核心:热键快捷键编码/冲突、托盘菜单模型、muses:// 深链解析、
/// NowPlayingManager 的 MPRepeatType→RepeatMode 映射。Carbon/AppKit/NSPanel 的注册与
/// 窗口呈现属运行时表面,在 headless CI 无法稳定验证,故保留为手动/平台验证项(§15)。
@MainActor
@Suite("Phase 24 Desktop Integration")
struct Phase24DesktopIntegrationTests {

    private func snap(_ title: String, artist: String = "A", id: UUID = UUID()) -> TrackSnapshot {
        TrackSnapshot(id: id, title: title, artist: artist, albumTitle: nil,
                      durationSeconds: 200, filePath: "/tmp/x.wav", youTubeId: nil,
                      artworkHash: nil, artworkUrl: nil,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    // MARK: - HotkeyShortcut 编码 + 冲突检测

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
            "b": HotkeyShortcut(keyCode: 1, modifiers: 9),   // 与 a 相同 → 冲突
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
        // 无曲目 → play/next/prev/like/inbox 禁用
        for kind in [TrayMenuModel.Item.Kind.playPause, .next, .previous, .like, .addToInbox] {
            let item = empty.first { $0.kind == kind }!
            #expect(item.enabled == false)
        }
        // openMini/openMain/quit 始终启用
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
        #expect(TrayMenuModel.kind(for: 999) == nil)   // 未知 tag
    }

    // MARK: - muses:// 深链解析(CFBundleURLTypes 修复后由系统路由)

    @Test("SpotlightIndexer.trackId(from:):muses://play?trackId=<uuid> 解析")
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

    // MARK: - NowPlayingManager.repeatMode 映射(纯函数)

    @Test("repeatMode(from:):off/all/one 直映;未知保持当前")
    func repeatModeMapping() {
        #expect(NowPlayingManager.repeatMode(from: .off, current: .all) == .off)
        #expect(NowPlayingManager.repeatMode(from: .all, current: .off) == .all)
        #expect(NowPlayingManager.repeatMode(from: .one, current: .off) == .one)
        // @unknown default 走不到(枚举已覆盖),仅验证不崩。
        #expect(NowPlayingManager.repeatMode(from: .all, current: .one) == .all)
    }

    // MARK: - Info.plist CFBundleURLTypes 注册(运行时验证:读 bundle)

    @Test("Info.plist:CFBundleURLTypes 注册 muses scheme")
    func infoPlistURLSchemeRegistered() throws {
        // 测试 host 进程的 Info.plist(由 SwiftPM 资源拷贝)。注册缺失时跳过断言而非失败,
        // 因 headless 测试 bundle 可能未含 Info.plist(§15:绝不伪造)。
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            // 测试进程无 Info.plist 时,直接校验源 plist 文件内容(开发态保证)。
            try verifySourceInfoPlistHasScheme()
            return
        }
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("muses"))
    }

    private func verifySourceInfoPlistHasScheme() throws {
        let url = Bundle.main.url(forResource: "Info", withExtension: "plist")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Muses/Sources/Muses/Resources/Info.plist")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Info.plist 不存在:\(url.path)"); return
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        let types = (plist["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("muses"))
    }
}