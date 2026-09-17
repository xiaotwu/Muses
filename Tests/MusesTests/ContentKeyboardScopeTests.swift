import Testing
@testable import Muses

@Suite("Content keyboard scope")
struct ContentKeyboardScopeTests {
    @Test func playbackShortcutsYieldToTextEditingAndSheets() {
        #expect(ContentKeyboardScope.acceptsShortcuts(
            firstResponderIsTextInput: false,
            hasPresentedSheet: false
        ))
        #expect(!ContentKeyboardScope.acceptsShortcuts(
            firstResponderIsTextInput: true,
            hasPresentedSheet: false
        ))
        #expect(!ContentKeyboardScope.acceptsShortcuts(
            firstResponderIsTextInput: false,
            hasPresentedSheet: true
        ))
    }
}
