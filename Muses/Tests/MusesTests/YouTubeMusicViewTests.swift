import Testing
import SwiftUI
@testable import Muses

/// YouTube Music 合并视图冒烟测试。
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
        // 只验证返回非空字符串(实际语言由系统 locale 决定)
        #expect(!YouTubeMusicView.YTMTab.search.label.isEmpty)
        #expect(!YouTubeMusicView.YTMTab.imports.label.isEmpty)
    }
}