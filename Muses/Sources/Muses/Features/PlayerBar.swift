import SwiftUI
import AppKit

struct PlayerBar: View {
    @Environment(PlaybackService.self) private var playback
    @State private var seeking = false
    @State private var seekValue: Double = 0
    var onArtworkTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            leadingBlock
            centerBlock
            trailingBlock
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)), alignment: .top)
    }

    private var leadingBlock: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 56, height: 56)
                .cornerRadius(6)
                .onTapGesture { onArtworkTap() }
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.state.track?.title ?? "").font(.callout).lineLimit(1).foregroundStyle(.white)
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
                    .foregroundStyle(.white)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .foregroundStyle(BrandColors.magenta)
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
                    .foregroundStyle(.white)
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
            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 100).tint(BrandColors.cyan)
            Button { } label: { Image(systemName: "list.bullet") }.foregroundStyle(BrandColors.textSecondary)
            Button { } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}