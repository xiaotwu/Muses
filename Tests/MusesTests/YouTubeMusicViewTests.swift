import Testing
import SwiftUI
@testable import Muses

/// YouTube Music merged-view smoke tests.
@MainActor
@Suite("YouTubeMusicView")
struct YouTubeMusicViewTests {

    @Test("YTMTab 包含 search 与 imports 两个标签")
    func tabHasTwoCases() {
        #expect(YouTubeMusicView.YTMTab.allCases.count == 2)
        #expect(YouTubeMusicView.YTMTab.allCases.contains(.search))
        #expect(YouTubeMusicView.YTMTab.allCases.contains(.imports))
    }

    @Test("YTMTab label 本地化")
    func tabLabelLocalized() {
        // Just assert a non-empty string (the actual language depends on the system locale)
        #expect(!YouTubeMusicView.YTMTab.search.label.isEmpty)
        #expect(!YouTubeMusicView.YTMTab.imports.label.isEmpty)
    }
}