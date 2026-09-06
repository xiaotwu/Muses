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

    @Test("cookieArgs none → empty array")
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

    @Test("cookieArgs file with path → --cookies <path>")
    func fileWithPath() {
        saveAndSet(source: YTCookieSource.file.rawValue, path: "/tmp/cookies.txt")
        defer { clear() }
        #expect(bridge.cookieArgs() == ["--cookies", "/tmp/cookies.txt"])
    }

    @Test("cookieArgs file without path → empty array (safe fallback)")
    func fileEmptyPath() {
        saveAndSet(source: YTCookieSource.file.rawValue, path: "")
        defer { clear() }
        #expect(bridge.cookieArgs().isEmpty)
    }

    @Test("cookieArgs unset → defaults to none empty array")
    func unsetDefaultsToNone() {
        clear()
        #expect(bridge.cookieArgs().isEmpty)
    }
}