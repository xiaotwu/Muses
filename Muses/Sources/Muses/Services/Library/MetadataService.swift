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
    var bitRate: Int?
    var channels: Int?
    var codec: String?
    var isLossless: Bool
    var artworkData: Data?
    /// ReplayGain track gain(dB),如 -6.43。nil 表示无标签。
    var replayGain: Double?
}

final class MetadataService: Sendable {
    let artworkCache: ArtworkCache
    init(artworkCache: ArtworkCache) { self.artworkCache = artworkCache }

    func readEmbedded(at url: URL) async -> EmbeddedMetadata? {
        let asset = AVURLAsset(url: url)
        var meta = EmbeddedMetadata(
            title: nil, artist: nil, albumTitle: nil, albumArtist: nil,
            durationMs: 0, trackNo: nil, discNo: nil, year: nil, genre: nil,
            sampleRate: nil, bitDepth: nil, bitRate: nil, channels: nil,
            codec: nil, isLossless: false,
            artworkData: nil, replayGain: nil)

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
                    meta.channels = Int(basic.mChannelsPerFrame)
                    break
                }
            }

            // 估算比特率(bits/s):AVAssetTrack.estimatedDataRate 为 bits/s。
            // 压缩格式(aac/mp3/opus)有意义;无损(pcm/alac/flac)可据此算采样率×位深×声道。
            if let audioTrack = tracks.first {
                let dataRate = try? await audioTrack.load(.estimatedDataRate)
                if let dr = dataRate, dr > 0 {
                    meta.bitRate = Int(dr)
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

            // ReplayGain 标签不在 commonMetadata 中,需遍历完整 metadata 列表
            // 按 key 字符串匹配(ID3 TXXX:REPLAYGAIN_TRACK_GAIN / Vorbis REPLAYGAIN_TRACK_GAIN /
            // MP4 ----:com.apple.iTunes:replaygain_track_gain)
            if meta.replayGain == nil {
                for item in try await asset.load(.metadata) {
                    let keyString = (item.key as? String) ?? (item.identifier?.rawValue ?? "")
                    let lower = keyString.lowercased()
                    if lower.contains("replaygain_track_gain") || lower == "replaygain_track_gain" {
                        if let val = try? await item.load(.stringValue) {
                            meta.replayGain = Self.parseReplayGain(val)
                            if meta.replayGain != nil { break }
                        }
                    }
                }
            }
        } catch {
            AppLog.for("MetadataService").error("read failed \(url): \(error)")
            return nil
        }
        return meta
    }

    /// 解析 ReplayGain 字符串(如 "-6.43 dB" → -6.43)。纯函数,便于测试。
    static func parseReplayGain(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // 去掉 "dB" 后缀
        let withoutDB = trimmed.replacingOccurrences(of: "dB", with: "",
                                                     options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return Double(withoutDB)
    }

    /// 计算 ReplayGain 增益因子:scale = 10^(gain/20)。nil 或 0 dB → 1.0。
    static func replayGainScale(_ gain: Double?) -> Float {
        guard let gain else { return 1.0 }
        return Float(pow(10.0, gain / 20.0))
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