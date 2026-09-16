enum PlaybackPrimaryAction {
    case play, pause, retry
    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .retry: "arrow.clockwise"
        }
    }
    var title: String {
        switch self {
        case .play: tr("Play", "播放")
        case .pause: tr("Pause", "暂停")
        case .retry: tr("Retry", "重试", zhHant: "重試")
        }
    }
}
