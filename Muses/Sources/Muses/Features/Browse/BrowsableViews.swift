import SwiftUI
import AppKit

// MARK: - Cards

/// 派生专辑卡片(YouTube-derived)。带 YT 来源标识 + 置信度点。
/// 本地专辑沿用既有 `AlbumCard`(直接渲染 `Album` @Model)。
struct BrowsableAlbumCard: View {
    let browsable: BrowsableAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(source: ArtworkSource.resolve(for: browsable), cornerRadius: 8, glyphSize: 60)
                .frame(width: 200, height: 200)
                .overlay(alignment: .topTrailing) { sourceBadge }
            Text(browsable.title).font(.subheadline)
                .foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text(browsable.artistName).font(.caption)
                .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
        }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Circle().fill(BrandColors.surface).frame(width: 200, height: 200)
                ArtworkView(source: ArtworkSource.resolve(for: browsable),
                            cornerRadius: 100, glyphSize: 60)
                    .frame(width: 200, height: 200).clipShape(Circle())
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "play.rectangle.fill").font(.caption2)
                    .padding(5).background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(BrandColors.textPrimary).padding(6)
            }
            Text(browsable.name).font(.subheadline)
                .foregroundStyle(BrandColors.textPrimary).lineLimit(1)
            Text("\(browsable.trackCount) \(tr("songs", "首歌曲"))").font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }
}

// MARK: - Track snapshot row (derived detail 用;不依赖 @Model)

struct TrackSnapshotRow: View {
    let snapshot: TrackSnapshot
    var index: Int? = nil
    var body: some View {
        HStack {
            if let index {
                Text("\(index)").foregroundStyle(BrandColors.textSecondary)
                    .frame(width: 28, alignment: .trailing)
            }
            VStack(alignment: .leading) {
                Text(snapshot.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(snapshot.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(formatDuration(snapshot.durationSeconds))
                .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.vertical, 6)
    }

    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Derived detail views

/// 派生专辑详情:由 YouTube 曲目支撑,无 @Model;play-all 用 PlaybackService。
struct DerivedAlbumDetailView: View {
    let browsable: BrowsableAlbum
    @Binding var selection: BrowsableAlbum?
    @Environment(PlaybackService.self) private var playback

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
            ArtworkView(source: ArtworkSource.resolve(for: browsable), cornerRadius: 12, glyphSize: 60)
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
                TrackSnapshotRow(snapshot: snap, index: idx + 1)
                    .onTapGesture { play(snap) }
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
            ArtworkView(source: ArtworkSource.resolve(for: browsable), cornerRadius: 100, glyphSize: 60)
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
                TrackSnapshotRow(snapshot: snap, index: idx + 1)
                    .onTapGesture { play(snap) }
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