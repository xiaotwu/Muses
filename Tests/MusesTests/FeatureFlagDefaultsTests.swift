import Testing
import Foundation
@testable import Muses

/// Consistency cleanup: feature-flag default on/off inventory.
///
/// Active in-app feature flags default on; desktop utilities default off.
/// Retired local-file flags are deliberately absent from runtime defaults.
@MainActor
struct FeatureFlagDefaultsTests {

    @Test("In-app feature flags and menu bar icon default on")
    func inAppFlagsDefaultOn() {
        let on = FeatureFlagDefaults.enabledByDefault
        #expect(on[PrefKey.ffSmartHistory] == true)
        #expect(on[PrefKey.ffSessions] == true)
        #expect(on[PrefKey.ffAdvancedQueue] == true)
        #expect(on[PrefKey.ffNotes] == true)
        #expect(on[PrefKey.ffContext] == true)
        #expect(on[PrefKey.ffAudioNerd] == true)
        #expect(on[PrefKey.ffDiscovery] == true)
        #expect(on[PrefKey.ffSituationalNew] == true)
        #expect(on[PrefKey.ffTray] == true)
    }

    @Test("Global hotkeys, mini player, and desktop lyrics are not enabled by default")
    func desktopFlagsNotInDefaultOn() {
        let on = FeatureFlagDefaults.enabledByDefault
        #expect(on[PrefKey.ffGlobalHotkeys] == nil)
        #expect(on[PrefKey.ffMiniPlayer] == nil)
        #expect(on[PrefKey.ffDesktopLyrics] == nil)
    }

    @Test("Inventory contains 9 keys including tray icon, excluding retired flags")
    func exactlyNineFlags() {
        #expect(FeatureFlagDefaults.enabledByDefault.count == 9)
        #expect(FeatureFlagDefaults.enabledByDefault.keys.contains { $0.contains("advancedLyrics") } == false)
    }
}
