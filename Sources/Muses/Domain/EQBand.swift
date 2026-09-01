import Foundation

struct EQBand: Codable, Equatable, Sendable {
    var frequency: Double      // Hz
    var gain: Float            // dB, -24...24
    var q: Float               // Bandwidth factor, 0.1...10

    init(frequency: Double, gain: Float, q: Float) {
        self.frequency = frequency; self.gain = gain; self.q = q
    }
}

enum EQPresets {
    static let flat: [EQBand] = [
        EQBand(frequency: 31, gain: 0, q: 1.0),
        EQBand(frequency: 62, gain: 0, q: 1.0),
        EQBand(frequency: 125, gain: 0, q: 1.0),
        EQBand(frequency: 250, gain: 0, q: 1.0),
        EQBand(frequency: 500, gain: 0, q: 1.0),
        EQBand(frequency: 1000, gain: 0, q: 1.0),
        EQBand(frequency: 2000, gain: 0, q: 1.0),
        EQBand(frequency: 4000, gain: 0, q: 1.0),
        EQBand(frequency: 8000, gain: 0, q: 1.0),
        EQBand(frequency: 16000, gain: 0, q: 1.0)
    ]
}