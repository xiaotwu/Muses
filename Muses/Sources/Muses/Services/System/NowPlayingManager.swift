import Foundation
import MediaPlayer
import AppKit
import UserNotifications

/// 管理 MPNowPlayingInfoCenter(锁屏/控制中心元信息)与 MPRemoteCommandCenter(媒体键)。
/// 通过单一生命周期同步 PlaybackService.state → nowPlayingInfo; 绑定远程命令转发回 PlaybackService。
/// 可选:换歌时发本地通知(opt-in via @AppStorage PrefKey.notificationsTrackChange)。
@MainActor
final class NowPlayingManager {
    let playback: PlaybackService
    private var updateTask: Task<Void, Never>?
    private(set) var observationLifecycleStartCount = 0
    private var lastNotifiedTrackId: UUID?

    init(_ playback: PlaybackService) {
        self.playback = playback
        bindCommands()
        startObserving()
    }

    deinit {
        updateTask?.cancel()
    }

    // MARK: - 状态观察

    /// 启动唯一的状态发布循环。重复调用保持幂等,不创建额外 Task。
    func startObserving() {
        guard updateTask == nil else { return }
        observationLifecycleStartCount += 1
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.updateInfo()
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - nowPlayingInfo

    private func updateInfo() {
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

        // 换歌通知(opt-in)
        if let track = state.track, track.id != lastNotifiedTrackId {
            lastNotifiedTrackId = track.id
            sendTrackChangeNotification(title: track.title, body: track.artist)
        }
    }

    // MARK: - 换歌通知

    private func sendTrackChangeNotification(title: String, body: String) {
        let enabled = UserDefaults.standard.bool(forKey: PrefKey.notificationsTrackChange)
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "muses.track.\(UUID().uuidString)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 请求通知授权(在用户首次开启通知时调用)。
    func requestNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        return granted
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
