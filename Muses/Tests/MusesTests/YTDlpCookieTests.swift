import Testing
import Foundation
@testable import Muses

/// yt-dlp cookie 参数构造测试。
/// 验证 `YTDlpBridge.cookieArgs()` 根据 UserDefaults 设置返回正确的
/// `--cookies-from-browser` / `--cookies` 参数。
@MainActor
@Suite("YTDlpCookie")
struct YTDlpCookieTests {

    private let defaults = UserDefaults.standard
    private let bridge = YTDlpBridge()

    /// 保存并恢复原始 UserDefaults 值,避免跨测试污染。
    private func saveAndSet(source: String, path: String = "") {
        defaults.set(source, forKey: PrefKey.ytCookieSource)
        defaults.set(path, forKey: PrefKey.ytCookiePath)
    }

    private func clear() {
        defaults.removeObject(forKey: PrefKey.ytCookieSource)
        defaults.removeObject(forKey: PrefKey.ytCookiePath)
    }

    @Test("cookieArgs none → 空数组")
    func noneReturnsEmpty() {
        saveAndSet(source: YTCookieSource.none.rawValue)
        defer { clear() }
        #expect(bridge.cookieArgs().isEmpty)
    }

    @Test("cookieArgs safari → --cookies-from-browser safari")
    func safariArgs() {
        saveAndSet(source: YTCookieSource.safari.rawValue)
        defer { clear() }
        #expect(bridge.cookieArgs() == ["--cookies-from-browser", "safari"])
    }

    @Test("cookieArgs chrome → --cookies-from-browser chrome")
    func chromeArgs() {
        saveAndSet(source: YTCookieSource.chrome.rawValue)
        defer { clear() }
        #expect(bridge.cookieArgs() == ["--cookies-from-browser", "chrome"])
    }

    @Test("cookieArgs file 有路径 → --cookies <path>")
    func fileWithPath() {
        saveAndSet(source: YTCookieSource.file.rawValue, path: "/tmp/cookies.txt")
        defer { clear() }
        #expect(bridge.cookieArgs() == ["--cookies", "/tmp/cookies.txt"])
    }

    @Test("cookieArgs file 无路径 → 空数组(安全回退)")
    func fileEmptyPath() {
        saveAndSet(source: YTCookieSource.file.rawValue, path: "")
        defer { clear() }
        #expect(bridge.cookieArgs().isEmpty)
    }

    @Test("cookieArgs 未设置 → 默认 none 空数组")
    func unsetDefaultsToNone() {
        clear()
        #expect(bridge.cookieArgs().isEmpty)
    }
}