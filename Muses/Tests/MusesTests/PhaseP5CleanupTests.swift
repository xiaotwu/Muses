import Testing
import Foundation
@testable import Muses

/// P5 — 一致性清理:功能标志默认开关清单(issue #7)。
///
/// 用户显式选择「全部启用」:应用内功能标志默认开;桌面集成 4 项(全局热键/托盘/
/// 迷你播放器/桌面歌词)默认关——占用系统资源、不打扰。此测试固化该决策,防止回退。
@MainActor
struct PhaseP5CleanupTests {

    @Test("12 项应用内功能标志默认开启")
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
        #expect(on[PrefKey.ffLocalHardening] == true)
        #expect(on[PrefKey.ffFocusMode] == true)
        #expect(on[PrefKey.ffDiscovery] == true)
        #expect(on[PrefKey.ffSituationalNew] == true)
    }

    @Test("桌面集成 4 项不在默认开启清单(仍默认关,不打扰)")
    func desktopFlagsNotInDefaultOn() {
        let on = FeatureFlagDefaults.enabledByDefault
        #expect(on[PrefKey.ffGlobalHotkeys] == nil)
        #expect(on[PrefKey.ffTray] == nil)
        #expect(on[PrefKey.ffMiniPlayer] == nil)
        #expect(on[PrefKey.ffDesktopLyrics] == nil)
    }

    @Test("清单仅含 12 个键(无意外项)")
    func exactlyTwelveFlags() {
        #expect(FeatureFlagDefaults.enabledByDefault.count == 12)
    }
}