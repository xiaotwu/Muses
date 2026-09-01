import SwiftUI

enum MusesMotion {
    static let hover: TimeInterval = 0.15
    static let overlay: TimeInterval = 0.20
    static let drawer: TimeInterval = 0.25
    static let nowPlayingMorph: TimeInterval = 0.32
    static let collectionDeckSnap: TimeInterval = 0.22
    static let collectionListTransition: TimeInterval = 0.29
    static let collectionCardActivation: TimeInterval = 0.30

    static func hoverAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: hover)
    }

    static func morphAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: nowPlayingMorph)
    }

    static func drawerAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: drawer)
    }

    static func overlayAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: overlay)
    }

    static func collectionDeckAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: collectionDeckSnap)
    }

    static func collectionListAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: collectionListTransition)
    }

    static func collectionCardAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: collectionCardActivation)
    }
}
