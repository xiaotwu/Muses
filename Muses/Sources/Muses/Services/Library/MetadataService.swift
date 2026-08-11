import Foundation
import AVFoundation

struct EmbeddedMetadata: Sendable {
    var title: String?
    var artist: String?
    var albumTitle: String?
    var albumArtist: String?
    var durationMs: Int
    var trackNo: Int?
    var discNo: Int?
    var year: Int?
    var genre: String?
    var sampleRate: Int?
    var bitDepth: Int?
    var codec: String?
    var isLossless: Bool
    var artworkData: Data?
}

final class MetadataService: Sendable {
    let artworkCache: ArtworkCache
    init(artworkCache: ArtworkCache) { self.artworkCache = artworkCache }

    func readEmbedded(at url: URL) async -> EmbeddedMetadata? {
        let asset = AVURLAsset(url: url)
        var meta = EmbeddedMetadata(
            title: nil, artist: nil, albumTitle: nil, albumArtist: nil,
            durationMs: 0, trackNo: nil, discNo: nil, year: nil, genre: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false, artworkData: nil)

        do {
            let duration = try await asset.load(.duration)
            meta.durationMs = Int(CMTimeGetSeconds(duration) * 1000)

            let tracks = try await asset.load(.tracks)
            for track in tracks {
                let descriptions = try await track.load(.formatDescriptions)
                if let fmt = descriptions.first,
                   let basic = fmt.audioStreamBasicDescription {
                    let codec = codecName(from: basic.mFormatID)
                    meta.codec = codec
                    meta.isLossless = (codec == "alac" || codec == "flac")
                    meta.sampleRate = Int(basic.mSampleRate)
                    meta.bitDepth = Int(basic.mBitsPerChannel)
                    break
                }
            }

            for format in try await asset.load(.commonMetadata) {
                let key = format.commonKey
                switch key {
                case .commonKeyTitle: meta.title = try? await format.load(.stringValue)
                case .commonKeyArtist: meta.artist = try? await format.load(.stringValue)
                case .commonKeyAlbumName: meta.albumTitle = try? await format.load(.stringValue)
                case .commonKeyArtwork:
                    meta.artworkData = try? await format.load(.dataValue)
                case .commonKeyType: meta.genre = try? await format.load(.stringValue)
                default: break
                }
            }
        } catch {
            AppLog.for("MetadataService").error("read failed \(url): \(error)")
            return nil
        }
        return meta
    }

    private func codecName(from formatID: FourCharCode) -> String {
        switch formatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE: return "aac"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatOpus: return "opus"
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatMPEG4CELP: return "celp"
        case kAudioFormatLinearPCM: return "pcm"
        default: return String(decoding: formatID.char4Bytes.prefix(while: { $0 != 0 }),
                               as: UTF8.self).lowercased()
        }
    }
}

private extension FourCharCode {
    var char4Bytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
         UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF), 0]
    }
}