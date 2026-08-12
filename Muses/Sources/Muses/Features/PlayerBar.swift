import SwiftUI
import AppKit

struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @State private var seeking = false
    @State private var seekValue: Double = 0
    var onArtworkTap: () -> Void = {}
    var onQueueTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            leadingBlock
            centerBlock
            trailingBlock
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(BrandColors.hairline), alignment: .top)
    }

    private var leadingBlock: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 56, height: 56)
                .cornerRadius(6)
                .onTapGesture { onArtworkTap() }
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.state.track?.title ?? "").font(.callout).lineLimit(1).foregroundStyle(BrandColors.textPrimary)
                Text(playback.state.track?.artist ?? "").font(.caption)
                    .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
        }
    }

    private var artwork: some View {
        Group {
            if let h = playback.state.track?.artworkHash,
               let p = ArtworkCache.default.path(forHash: h) {
                Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
            } else {
                Rectangle().fill(BrandColors.surface)
            }
        }
        .clipped()
    }

    private var centerBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 24) {
                Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                    .foregroundStyle(BrandColors.textPrimary)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .foregroundStyle(BrandColors.magenta)
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(format(playback.state.position)).font(.caption2).foregroundStyle(BrandColors.textSecondary)
                Slider(value: Binding(
                    get: { seeking ? seekValue : playback.state.position },
                    set: { v in seeking = true; seekValue = v }),
                      in: 0...max(playback.state.duration, 1),
                    onEditingChanged: { end in
                        if end { playback.seek(to: seekValue); seeking = false }
                    })
                .tint(BrandColors.magenta)
                Text(format(playback.state.duration)).font(.caption2).foregroundStyle(BrandColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var trailingBlock: some View {
        HStack(spacing: 16) {
            // 收藏当前曲目(访问 likedRevision 注册 @Observable 依赖)
            let _ = library.likedRevision
            let liked = playback.state.track.map { library.isLiked(id: $0.id) } ?? false
            Button {
                if let id = playback.state.track?.id { library.toggleLike(id: id) }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
            }
            .foregroundStyle(liked ? BrandColors.magenta : BrandColors.textSecondary)
            .buttonStyle(.plain)
            .help(liked ? "取消收藏" : "收藏")

            // Repeat 模式循环:off → all → one
            Button {
                let next: RepeatMode
                switch playback.queue.repeatMode {
                case .off:  next = .all
                case .all:  next = .one
                case .one:  next = .off
                }
                playback.queue.setRepeat(next)
            } label: {
                Image(systemName: playback.queue.repeatMode == .one ? "repeat.1" : "repeat")
            }
            .foregroundStyle(playback.queue.repeatMode == .off
                             ? BrandColors.textSecondary : BrandColors.magenta)
            .buttonStyle(.plain)
            .help(repeatHelp)

            // Shuffle 切换
            Button {
                playback.queue.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
            }
            .foregroundStyle(playback.queue.shuffle
                             ? BrandColors.magenta : BrandColors.textSecondary)
            .buttonStyle(.plain)
            .help(playback.queue.shuffle ? "随机:开" : "随机:关")

            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 100).tint(BrandColors.cyan)
            Button { onQueueTap() } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private var repeatHelp: String {
        switch playback.queue.repeatMode {
        case .off: "循环:关"
        case .all: "循环:全部"
        case .one: "循环:单曲"
        }
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}