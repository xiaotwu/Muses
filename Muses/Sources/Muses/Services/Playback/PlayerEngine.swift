import Foundation

@MainActor
protocol PlayerEngine: AnyObject {
    var state: PlayerState { get }
    func load(_ track: TrackSnapshot) async throws
    func play()
    func pause()
    func toggle()
    func seek(to time: Double)
    func setVolume(_ v: Float)
    func setEQ(_ bands: [EQBand])
    func installSpectrumTap(_ handler: @escaping (SpectrumFrame) -> Void)
    func removeSpectrumTap()
}