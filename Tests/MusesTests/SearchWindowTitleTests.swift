import AppKit
import Testing
@testable import Muses

@Suite("Search window title") @MainActor
struct SearchWindowTitleTests {
    @Test func titleUpdatesWithoutChangingWindowIdentity() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        for title in ["Search Muses", "搜索 Muses", "搜尋 Muses"] {
            SearchWindowConfigurationView.configure(window, colorScheme: .light, title: title)
            #expect(window.title == title)
            #expect(window.identifier?.rawValue == "Muses.search-window")
            #expect(window.contentMinSize.width == 600)
        }
    }
}
