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
    /// Phase 24:`likeCommand` 需要库;`changeRepeatMode/changeShuffleMode` 需要队列。
    /// 均可选:测试或不接线时为 nil,对应远程命令不绑定(绝不伪造)。
    private let library: LibraryService?
    private let queue: QueueService?
    private var updateTask: Task<Void, Never>?
    private let publishInfo: ([String: Any]) -> Void
    private(set) var observationLifecycleStartCount = 0
    private var lastNotifiedTrackId: UUID?

    init(_ playback: PlaybackService,
         library: LibraryService? = nil,
         queue: QueueService? = nil,
         bindsRemoteCommands: Bool = true,
         publishInfo: @escaping ([String: Any]) -> Void = {
             MPNowPlayingInfoCenter.default().nowPlayingInfo = $0
         }) {
        self.playback = playback
        self.library = library
        self.queue = queue
        self.publishInfo = publishInfo
        if bindsRemoteCommands {
            bindCommands()
        }
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
            info[MPMediaItemPropertyPlaybackDuration] = state.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.position
            info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        }

        publishInfo(info)

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
            Task { @MainActor in self?.handleRemotePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handleRemotePause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handleRemoteToggle() }
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

        // Phase 24:补齐 like / repeat / shuffle 远程命令(Final Spec §10.1)。
        // 仅在接入 library / queue 时绑定;未接入则跳过,绝不伪造(§15)。
        if library != nil {
            center.likeCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.handleLike() }
                return .success
            }
        }
        if queue != nil {
            center.changeRepeatModeCommand.addTarget { [weak self] event in
                guard let self,
                      let ev = event as? MPChangeRepeatModeCommandEvent else {
                    return .commandFailed
                }
                Task { @MainActor in self.handleChangeRepeat(ev.repeatType) }
                return .success
            }
            center.changeShuffleModeCommand.addTarget { [weak self] event in
                guard let self,
                      let ev = event as? MPChangeShuffleModeCommandEvent else {
                    return .commandFailed
                }
                Task { @MainActor in self.queue?.toggleShuffle() }
                _ = ev   // 仅消费事件;shuffle 状态由队列持有
                return .success
            }
        }
    }

    /// Explicit remote actions are deliberately separate from toggle. Media
    /// services may repeat play/pause commands, and both must remain idempotent.
    func handleRemotePlay() {
        playback.play()
    }

    func handleRemotePause() {
        playback.pause()
    }

    func handleRemoteToggle() {
        playback.toggle()
    }

    // MARK: - Phase 24 远程命令处理

    private func handleLike() {
        guard let library, let id = playback.state.track?.id else { return }
        library.toggleLike(id: id)
    }

    private func handleChangeRepeat(_ type: MPRepeatType) {
        guard let queue else { return }
        queue.setRepeat(Self.repeatMode(from: type, current: queue.repeatMode))
    }

    /// MPRepeatType → RepeatMode:直映 off/all/one。系统不提供 `.default`,保持确定映射。
    static func repeatMode(from type: MPRepeatType, current: RepeatMode) -> RepeatMode {
        switch type {
        case .off:        return .off
        case .all:        return .all
        case .one:        return .one
        @unknown default: return current
        }
    }
}
