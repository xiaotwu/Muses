import Foundation
import Testing
@testable import Muses

@Suite("Domain Models")
struct DomainModelTests {

    @Test("Track source enum round-trips")
    func trackSourceRoundTrip() throws {
        #expect(TrackSource.local.rawValue == "local")
        #expect(TrackSource.youtube.rawValue == "youtube")
        let data = try JSONEncoder().encode(TrackSource.youtube)
        let back = try JSONDecoder().decode(TrackSource.self, from: data)
        #expect(back == .youtube)
    }

    @Test("EQBand is codable and equatable")
    func eqBandCodable() throws {
        let band = EQBand(frequency: 1000, gain: 3.0, q: 1.0)
        let data = try JSONEncoder().encode(band)
        let back = try JSONDecoder().decode(EQBand.self, from: data)
        #expect(back == band)
    }

    @Test("SpectrumFrame has 64 bands")
    func spectrumFrameBands() {
        let frame = SpectrumFrame(bands: Array(repeating: 0.5, count: 64), timestamp: 0)
        #expect(frame.bands.count == 64)
    }
}