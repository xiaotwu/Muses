import SwiftUI
import AppKit

// MARK: - Cards

/// 派生专辑卡片(YouTube-derived)。Album 对象 + YT 来源标识。
struct BrowsableAlbumCard: View {
    let browsable: BrowsableAlbum
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    var body: some View {
        AlbumObjectView(
            title: browsable.title,
            subtitle: browsable.artistName,
            artwork: ArtworkSource.resolve(for: browsable),
            size: MusicObjectMetrics.albumGrid,
            role: .browse,
            isNowPlaying: isNowPlaying,
            showsHoverPlay: showsHoverPlay,
            onSelect: onSelect,
            onPlay: onPlay
        )
        .overlay(alignment: .topTrailing) { sourceBadge }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.rectangle.fill").font(.caption2)
            Text("YT").font(.caption2.bold())
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(BrandColors.textPrimary)
        .padding(6)
    }
}

/// 派生艺术家卡片(圆形封面 + YT 来源标识)。
struct BrowsableArtistCard: View {
    let browsable: BrowsableArtist
    var isNowPlaying: Bool = false
    var showsHoverPlay: Bool = false
    var onSelect: () -> Void
    var onPlay: () -> Void

    var body: some View {
        ArtistObjectView(
            name: browsable.name,
            detail: "\(browsable.trackCount) \(tr("songs", "首歌曲"))",
            artwork: ArtworkSource.resolve(for: browsable),
            size: MusicObjectMetrics.artistGrid,
            isNowPlaying: isNowPlaying,
            showsHoverPlay: showsHoverPlay,
            onSelect: onSelect,
            onPlay: onPlay
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "play.rectangle.fill").font(.caption2)
                .padding(5).background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(BrandColors.textPrimary).padding(6)
        }
    }
}

// MARK: - Derived detail views

/// 派生专辑详情:由 YouTube 曲目支撑,无 @Model;play-all 用 PlaybackService。
struct DerivedAlbumDetailView: View {
    let browsable: BrowsableAlbum
    @Binding var selection: BrowsableAlbum?
    @Environment(PlaybackService.self) private var playback
    @State private var selectedTrackID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                trackList
            }
            .padding(24)
        }
        .navigationTitle(browsable.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .background(BrandColors.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            ArtworkView(source: ArtworkSource.resolve(for: browsable),
                        cornerRadius: 12, glyphSize: 60, targetSize: 160)
                .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("YouTube").font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(BrandColors.surface, in: Capsule())
                        .foregroundStyle(BrandColors.textSecondary)
                    if browsable.band == .tentative {
                        Text(tr("Tentative match", "暂定匹配")).font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }
                Text(browsable.title).font(.title).bold()
                    .foregroundStyle(BrandColors.textPrimary)
                Text(browsable.artistName).font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)
                if let year = browsable.year { Text("\(year)").font(.callout).foregroundStyle(BrandColors.textSecondary) }
                Button { playAll() } label: {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).tint(BrandColors.magenta)
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(browsable.trackSnapshots.enumerated()), id: \.element.id) { idx, snap in
                SongObjectView(
                    title: snap.title,
                    artist: snap.artist,
                    durationLabel: String(format: "%d:%02d", Int(snap.durationSeconds) / 60, Int(snap.durationSeconds) % 60),
                    indexLabel: "\(idx + 1)",
                    artwork: ArtworkSource.resolve(for: snap),
                    isSelected: selectedTrackID == snap.id,
                    nowPlayingID: snap.id,
                    showsHoverPlay: true,
                    isLossless: snap.isLossless,
                    onSelect: { selectedTrackID = snap.id; play(snap) },
                    onPlay: { play(snap) }
                )
                .trackContextMenu(snapshot: snap, onPlay: { play(snap) })
            }
        }
    }

    private func play(_ snap: TrackSnapshot) {
        playback.playTrack(snap, context: browsable.trackSnapshots, from: .album)
    }
    private func playAll() {
        guard let first = browsable.trackSnapshots.first else { return }
        play(first)
    }
}

/// 派生艺术家详情:列出该艺术家的 YouTube 曲目。
struct DerivedArtistDetailView: View {
    let browsable: BrowsableArtist
    @Binding var selection: BrowsableArtist?
    @Environment(PlaybackService.self) private var playback
    @State private var selectedTrackID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                trackList
            }
            .padding(24)
        }
        .navigationTitle(browsable.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = nil } label: { Image(systemName: "chevron.backward") }
            }
        }
        .background(BrandColors.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            ArtworkView(source: ArtworkSource.resolve(for: browsable),
                        glyphSize: 60, clipCircle: true, targetSize: 160)
                .frame(width: 160, height: 160).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text("YouTube").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(BrandColors.surface, in: Capsule())
                    .foregroundStyle(BrandColors.textSecondary)
                Text(browsable.name).font(.title).bold().foregroundStyle(BrandColors.textPrimary)
                Text("\(browsable.trackCount) \(tr("songs", "首歌曲"))").font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
                Button { playAll() } label: {
                    Label(tr("Play", "播放"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).tint(BrandColors.magenta)
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(browsable.trackSnapshots.enumerated()), id: \.element.id) { idx, snap in
                SongObjectView(
                    title: snap.title,
                    artist: snap.artist,
                    durationLabel: String(format: "%d:%02d", Int(snap.durationSeconds) / 60, Int(snap.durationSeconds) % 60),
                    indexLabel: "\(idx + 1)",
                    artwork: ArtworkSource.resolve(for: snap),
                    isSelected: selectedTrackID == snap.id,
                    nowPlayingID: snap.id,
                    showsHoverPlay: true,
                    isLossless: snap.isLossless,
                    onSelect: { selectedTrackID = snap.id; play(snap) },
                    onPlay: { play(snap) }
                )
                .trackContextMenu(snapshot: snap, onPlay: { play(snap) })
            }
        }
    }

    private func play(_ snap: TrackSnapshot) {
        playback.playTrack(snap, context: browsable.trackSnapshots, from: .artist)
    }
    private func playAll() {
        guard let first = browsable.trackSnapshots.first else { return }
        play(first)
    }
}