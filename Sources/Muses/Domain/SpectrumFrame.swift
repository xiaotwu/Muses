import Foundation

struct SpectrumFrame: Equatable, Sendable {
    let bands: [Float]    // 64 bands, normalized to 0...1
    let timestamp: Double
}