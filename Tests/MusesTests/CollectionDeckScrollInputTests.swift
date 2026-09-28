import Foundation
import Testing
@testable import Muses

@Suite("Collection deck wheel input")
struct CollectionDeckScrollInputTests {
    @Test("Down and right scroll toward later songs on the dominant axis")
    func direction() {
        #expect(CollectionDeckScrollInput.navigationDelta(horizontal: 0, vertical: -34) == 34)
        #expect(CollectionDeckScrollInput.navigationDelta(horizontal: -40, vertical: 5) == 40)
        #expect(CollectionDeckScrollInput.navigationDelta(horizontal: 40, vertical: -5) == -40)
        #expect(CollectionDeckScrollInput.navigationDelta(horizontal: 0, vertical: 34) == -34)
    }

    @Test("Small trackpad events accumulate without losing their remainder")
    func accumulate() {
        var input = CollectionDeckScrollInput()
        #expect(input.consume(delta: 20, timestamp: 1) == 0)
        #expect(input.consume(delta: 20, timestamp: 1.01) == 1)
        #expect(input.consume(delta: 28, timestamp: 1.02) == 1)
    }

    @Test("A new gesture cannot inherit a stale partial movement")
    func resetAfterPause() {
        var input = CollectionDeckScrollInput()
        #expect(input.consume(delta: 30, timestamp: 1) == 0)
        #expect(input.consume(delta: 10, timestamp: 1.2) == 0)
        #expect(input.consume(delta: -44, timestamp: 1.21) == -1)
    }

    @Test("Coarse wheel movement is bounded and reverses immediately")
    func coarseInput() {
        var input = CollectionDeckScrollInput()
        #expect(input.consume(delta: 340, timestamp: 1) == 3)
        #expect(input.consume(delta: -34, timestamp: 1.01) == -1)
    }
}
