import Foundation

struct SpectrumFrame: Equatable, Sendable {
    let bands: [Float]    // 64 bands, normalized to 0...1
    let timestamp: Double
}
/// Pull the newest sample on the display clock without queuing UI work.
final class SpectrumSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: SpectrumFrame?
    func write(_ frame: SpectrumFrame) {
        guard frame.bands.count == 64, lock.try() else { return }
        latest = frame
        lock.unlock()
    }
    func read() -> SpectrumFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
