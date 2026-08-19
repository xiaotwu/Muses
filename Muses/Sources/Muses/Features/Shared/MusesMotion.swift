import SwiftUI

enum MusesMotion {
    static let hover: TimeInterval = 0.15
    static let overlay: TimeInterval = 0.20
    static let drawer: TimeInterval = 0.25
    static let nowPlayingMorph: TimeInterval = 0.32

    static func hoverAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: hover)
    }

    static func morphAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: nowPlayingMorph)
    }
}
