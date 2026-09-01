import Foundation

@Observable
@MainActor
final class PlayerState {
    var track: TrackSnapshot?
    var isPlaying: Bool = false
    var position: Double = 0
    var duration: Double = 0
    var buffering: Bool = false
    var bufferRatio: Double = 0
    var quality: AudioQualityInfo?
    var error: PlayerError?

    init() {}
}

struct AudioQualityInfo: Equatable, Sendable {
    let sampleRate: Int
    let bitDepth: Int
    let codec: String
    let isLossless: Bool
}

enum PlayerError: LocalizedError, Equatable {
    case sourceUnavailable
    case embedUnavailable
    case networkError(String)
    case fileMissing(String)
    case decodingFailed(String)
    case engineStartFailed
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            tr("Audio source unavailable (removed or restricted)", "音频源不可用(下架或受限)")
        case .embedUnavailable:
            tr("YouTube embedding is disabled for this video", "此视频禁止嵌入播放")
        case .networkError(let m):
            tr("Network error: \(m)", "网络错误:\(m)")
        case .fileMissing(let p):
            tr("File missing: \(p)", "文件缺失:\(p)")
        case .decodingFailed(let m):
            tr("Decode failed: \(m)", "解码失败:\(m)")
        case .engineStartFailed:
            tr("Audio engine failed to start (device in use?)", "音频引擎启动失败(设备占用?)")
        case .rateLimited:
            tr("Rate limited, try again later", "请求被限流,请稍后重试")
        }
    }

    static func == (lhs: PlayerError, rhs: PlayerError) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}
