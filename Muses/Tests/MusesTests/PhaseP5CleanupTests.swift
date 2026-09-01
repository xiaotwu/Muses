import Testing
import Foundation
@testable import Muses

/// P5 — 一致性清理:功能标志默认开关清单(issue #7)。
///
/// Active in-app feature flags default on; desktop utilities default off.
/// Retired local-file flags are deliberately absent from runtime defaults.
@MainActor
struct PhaseP5CleanupTests {

    @Test("应用内功能标志与菜单栏图标默认开启")
    func inAppFlagsDefaultOn() {
        let on = FeatureFlagDefaults.enabledByDefault
        #expect(on[PrefKey.ffSmartHistory] == true)
        #expect(on[PrefKey.ffSessions] == true)
        #expect(on[PrefKey.ffAdvancedQueue] == true)
        #expect(on[PrefKey.ffInbox] == true)
        #expect(on[PrefKey.ffNotes] == true)
        #expect(on[PrefKey.ffContext] == true)
        #expect(on[PrefKey.ffAutomation] == true)
        #expect(on[PrefKey.ffAudioNerd] == true)
        #expect(on[PrefKey.ffLocalHardening] == nil)
        #expect(on[PrefKey.ffFocusMode] == true)
        #expect(on[PrefKey.ffDiscovery] == true)
        #expect(on[PrefKey.ffSituationalNew] == true)
        #expect(on[PrefKey.ffTray] == true)
    }

    @Test("全局热键/迷你播放器/桌面歌词不在默认开启清单")
    func desktopFlagsNotInDefaultOn() {
        let on = FeatureFlagDefaults.enabledByDefault
        #expect(on[PrefKey.ffGlobalHotkeys] == nil)
        #expect(on[PrefKey.ffMiniPlayer] == nil)
        #expect(on[PrefKey.ffDesktopLyrics] == nil)
    }

    @Test("清单含 12 个键(含菜单栏图标,不含退役的本地音乐强化)")
    func exactlyTwelveFlags() {
        #expect(FeatureFlagDefaults.enabledByDefault.count == 12)
    }
}
