import Foundation
import Testing
@testable import Muses

@Suite("Collection deck wheel input")
struct CollectionDeckScrollInputTests {
    @Test("Frame coalescing preserves distance and reversals without replaying old input")
    func frameCoalescing() {
        var input = CollectionDeckFrameInput()
        for _ in 0..<40 { input.append(0.25) }
        input.append(-2)
        let movement = input.take()
        let idle = input.take()
        #expect(movement == 8)
        #expect(idle == 0)
        input.append(1)
        input.append(-1)
        let reversal = input.take()
        #expect(reversal == 0)
    }
    @Test("Precise scrolling follows sub-threshold input and preserves direction and bounds")
    func continuousTrackpadMovement() {
        #expect(CollectionDeckScrollInput.preciseMovement(delta: 8.5) == 0.25)
        #expect(CollectionDeckScrollInput.preciseMovement(delta: -17) == -0.5)
        #expect(CollectionDeckScrollInput.preciseMovement(delta: 340) == 3)
        #expect(CollectionDeckScrollInput.preciseMovement(delta: -340) == -3)
        let position = (0..<40).reduce(CGFloat(0)) { value, _ in
            value + CollectionDeckScrollInput.preciseMovement(delta: 8.5)
        }
        #expect(position == 10)
    }
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
