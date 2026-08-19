import SwiftUI
import AppKit

/// Apple Music 风格的播放栏:左侧封面+标题+"…"溢出菜单,中央传输控件+进度条,
/// 右侧音量+歌词+队列。高度 64,玻璃材质,圆角 16。
struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(PlaylistService.self) private var playlistService
    @Environment(InboxService.self) private var inbox
    @Environment(\.artworkWorldNamespace) private var artworkWorldNamespace
    @State private var seeking = false
    @State private var seekValue: Double = 0
    var showNowPlaying: Bool = false
    var skipArtworkMorph: Bool = false
    var onArtworkTap: () -> Void = {}
    var onQueueTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            leadingBlock
            centerBlock
            trailingBlock
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .musesGlass(cornerRadius: 16)
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
    }

    // MARK: - 左侧:封面 + 标题/艺术家 + "…" 溢出菜单
    private var leadingBlock: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 52, height: 52)
                .cornerRadius(6)
                .onTapGesture { onArtworkTap() }
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.state.track?.title ?? "")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(BrandColors.textPrimary)
                Text(playback.state.track?.artist ?? "")
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .frame(width: 180, alignment: .leading)
            overflowMenu
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let art = ArtworkView(
            source: ArtworkSource.resolve(for: playback.state.track),
            cornerRadius: 6,
            glyphSize: 20,
            targetSize: 52
        )
        if let trackID = playback.state.track?.id,
           let ns = artworkWorldNamespace,
           !skipArtworkMorph {
            // Keep a 52pt token with the same liveCover id while NP is open so
            // the pair exists for morph. Hide pixels; do not drop the effect.
            Group {
                if showNowPlaying {
                    Color.clear
                } else {
                    art
                }
            }
            .frame(width: 52, height: 52)
            .matchedGeometryEffect(
                id: ArtworkContinuityID.liveCover(trackID),
                in: ns,
                isSource: !showNowPlaying
            )
        } else {
            art
        }
    }

    /// "…" 溢出菜单(图三):收藏 / 添加到歌单 / 显示在专辑中 / 显示在艺术家中 /
    /// 复制链接 / 共享… / 在 Now Playing 中展开。
    private var overflowMenu: some View {
        Menu {
            let _ = library.likedRevision
            let liked = playback.state.track.map { library.isLiked(id: $0.id) } ?? false
            Button {
                if let id = playback.state.track?.id { library.toggleLike(id: id) }
            } label: {
                Label(liked ? tr("Unfavorite", "取消收藏") : tr("Favorite", "收藏"),
                      systemImage: liked ? "heart.slash" : "heart")
            }

            // 添加到歌单(子菜单列出所有歌单)
            Menu {
                ForEach(playlistService.fetchAll(), id: \.id) { pl in
                    Button(pl.name) {
                        if let tid = playback.state.track?.id,
                           let t = library.track(by: tid) {
                            playlistService.addTrack(pl, track: t)
                        }
                    }
                }
            } label: {
                Label(tr("Add to Playlist…", "添加到歌单…"), systemImage: "text.badge.plus")
            }

            Button {
                if let snap = playback.state.track { inbox.add(snap) }
            } label: {
                Label(tr("Add to Inbox", "加入收件箱"), systemImage: "tray.and.arrow.down")
            }

            Divider()

            Button {
                if let tid = playback.state.track?.id,
                   let album = library.track(by: tid)?.album {
                    NotificationCenter.default.post(name: .musesNavigateAlbum, object: album)
                }
            } label: {
                Label(tr("Show in Album", "显示在专辑中"), systemImage: "music.square.stack")
            }

            Button {
                if let tid = playback.state.track?.id,
                   let artist = library.track(by: tid)?.artistRef {
                    NotificationCenter.default.post(name: .musesNavigateArtist, object: artist)
                }
            } label: {
                Label(tr("Show in Artist", "显示在艺术家中"), systemImage: "music.mic")
            }

            Divider()

            Button {
                copyLink()
            } label: {
                Label(tr("Copy Link", "复制链接"), systemImage: "link")
            }

            Button {
                shareTrack()
            } label: {
                Label(tr("Share…", "共享…"), systemImage: "square.and.arrow.up")
            }

            Divider()

            // 循环/随机(从栏内迁入菜单,保持可达)
            Button {
                let next: RepeatMode
                switch playback.queue.repeatMode {
                case .off:  next = .all
                case .all:  next = .one
                case .one:  next = .off
                }
                playback.queue.setRepeat(next)
            } label: {
                Label(repeatMenuLabel, systemImage: playback.queue.repeatMode == .one ? "repeat.1" : "repeat")
            }

            Button {
                playback.queue.toggleShuffle()
            } label: {
                Label(shuffleMenuLabel, systemImage: "shuffle")
            }

            Divider()

            Button {
                onArtworkTap()
            } label: {
                Label(tr("Open Now Playing", "在 Now Playing 中展开"), systemImage: "play.square")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(BrandColors.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 中央:传输控件 + 进度条
    private var centerBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                    .foregroundStyle(BrandColors.textPrimary)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .foregroundStyle(BrandColors.magenta)
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(format(playback.state.position))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(BrandColors.textSecondary)
                Slider(value: Binding(
                    get: { seeking ? seekValue : playback.state.position },
                    set: { v in seeking = true; seekValue = v }),
                      in: 0...max(playback.state.duration, 1),
                    onEditingChanged: { end in
                        if end { playback.seek(to: seekValue); seeking = false }
                    })
                .tint(BrandColors.magenta)
                Text(format(playback.state.duration))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 右侧:音量 + 歌词 + 队列
    private var trailingBlock: some View {
        HStack(spacing: 16) {
            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 90).tint(BrandColors.magenta)
            Button { onArtworkTap() } label: { Image(systemName: "quote.bubble") }
                .foregroundStyle(BrandColors.textSecondary)
                .buttonStyle(.plain)
                .help(tr("Lyrics", "歌词"))
            Button { onQueueTap() } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(BrandColors.textSecondary)
                .buttonStyle(.plain)
                .help(tr("Queue", "队列"))
        }
    }

    // MARK: - 溢出菜单动作
    private var repeatMenuLabel: String {
        switch playback.queue.repeatMode {
        case .off: tr("Repeat: Off", "循环:关")
        case .all: tr("Repeat: All", "循环:全部")
        case .one: tr("Repeat: One", "循环:单曲")
        }
    }
    private var shuffleMenuLabel: String {
        playback.queue.shuffle ? tr("Shuffle: On", "随机:开") : tr("Shuffle: Off", "随机:关")
    }

    private func copyLink() {
        let link: String
        if let vid = playback.state.track?.youTubeId {
            link = "https://youtu.be/\(vid)"
        } else {
            link = playback.state.track?.title ?? ""
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func shareTrack() {
        guard let track = playback.state.track else { return }
        var items: [Any] = [track.title]
        if let vid = track.youTubeId {
            items.append("https://youtu.be/\(vid)")
        }
        guard let window = NSApp.windows.first else { return }
        NSSharingServicePicker(items: items).show(relativeTo: .null, of: window.contentView ?? NSView(), preferredEdge: .minY)
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}