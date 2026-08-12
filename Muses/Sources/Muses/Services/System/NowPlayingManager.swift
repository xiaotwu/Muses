import Foundation
import MediaPlayer
import AppKit
import Observation

/// 管理 MPNowPlayingInfoCenter(锁屏/控制中心元信息)与 MPRemoteCommandCenter(媒体键)。
/// 订阅 PlaybackService.state 变化 → 更新 nowPlayingInfo; 绑定远程命令转发回 PlaybackService。
@MainActor
final class NowPlayingManager {
    let playback: PlaybackService
    private var updateTask: Task<Void, Never>?

    init(_ playback: PlaybackService) {
        self.playback = playback
        bindCommands()
        startObserving()
    }

    deinit {
        updateTask?.cancel()
    }

    // MARK: - 状态观察

    /// 用 withObservationTracking 递归追踪 state 变化(track/position/duration/isPlaying),
    /// 任一属性变更后重新拉取并更新 nowPlayingInfo。
    private func startObserving() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                withObservationTracking {
                    _ = self.playback.state.track?.title
                    _ = self.playback.state.position
                    _ = self.playback.state.duration
                    _ = self.playback.state.isPlaying
                } onChange: {
                    Task { @MainActor [weak self] in self?.startObserving() }
                }
                await self.updateInfo()
                // withObservationTracking 只在追踪的属性变化时触发 onChange,
                // 这里用短 sleep 作为 fallback 刷新间隔
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: - nowPlayingInfo

    private func updateInfo() async {
        var info: [String: Any] = [:]
        let state = playback.state

        if let track = state.track {
            info[MPMediaItemPropertyTitle] = track.title
            info[MPMediaItemPropertyArtist] = track.artist
            if let album = track.albumTitle {
                info[MPMediaItemPropertyAlbumTitle] = album
            }
            if let h = track.artworkHash, let data = ArtworkCache.default.data(forHash: h),
               let nsImage = NSImage(data: data) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: nsImage.size) { _ in nsImage }
            }
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.position
            info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 远程命令绑定

    private func bindCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback.toggle() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback.toggle() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playback.previous() }
            return .success
        }

        // 进度条拖动
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.playback.seek(to: posEvent.positionTime) }
            return .success
        }

        // 快进/快退 ±15s
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playback.seek(to: min(self.playback.state.duration,
                                           self.playback.state.position + 15))
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playback.seek(to: max(0, self.playback.state.position - 15))
            }
            return .success
        }
    }
}