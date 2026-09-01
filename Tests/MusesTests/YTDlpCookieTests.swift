import Testing
import Foundation
@testable import Muses

/// yt-dlp cookie argument construction tests.
/// Verifies that `YTDlpBridge.cookieArgs()` returns the correct
/// `--cookies-from-browser` / `--cookies` arguments based on UserDefaults.
@MainActor
@Suite("YTDlpCookie")
struct YTDlpCookieTests {

    private let defaults = UserDefaults.standard
    private let bridge = YTDlpBridge()

    /// Saves and restores the original UserDefaults values to avoid cross-test pollution.
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