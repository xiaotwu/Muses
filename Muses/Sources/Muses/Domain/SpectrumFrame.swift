import Foundation

struct SpectrumFrame: Equatable, Sendable {
    let bands: [Float]    // 64 段, 归一化 0...1
    let timestamp: Double
}