import SwiftUI
import AppKit

/// 全局搜索面板:中心浮层 + scrim,分 section 显示本地歌曲/专辑/艺术家 + YouTube 结果。
/// 克隆 QueueDrawerView 的 scrim+panel 模式,但居中而非 trailing。
struct GlobalSearchView: View {
    @Binding var isPresented: Bool
    @Environment(GlobalSearchService.self) private var search
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @Environment(YouTubeImportService.self) private var importService
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack {
            // scrim — 点击关闭
            BrandColors.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .frame(width: 560)
                .frame(maxHeight: 520)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(BrandColors.hairline, lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
        .onAppear { searchFieldFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(BrandColors.textSecondary)
                TextField("搜索歌曲、艺术家、专辑、YouTube…", text: Binding(
                    get: { search.query },
                    set: { search.query = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { /* debounce 自动触发 */ }

                if search.isSearchingYouTube {
                    ProgressView().controlSize(.small)
                }
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().background(BrandColors.hairline)

            // 结果
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !search.trackResults.isEmpty {
                        section(title: "歌曲", count: search.trackResults.count) {
                            ForEach(search.trackResults.prefix(8), id: \.id) { track in
                                GlobalSearchTrackRow(track: track) {
                                    play(track, from: search.trackResults)
                                }
                            }
                        }
                    }
                    if !search.artistResults.isEmpty {
                        section(title: "艺术家", count: search.artistResults.count) {
                            ForEach(search.artistResults.prefix(5), id: \.id) { artist in
                                GlobalSearchArtistRow(artist: artist) {
                                    navigateToArtist(artist)
                                }
                            }
                        }
                    }
                    if !search.albumResults.isEmpty {
                        section(title: "专辑", count: search.albumResults.count) {
                            ForEach(search.albumResults.prefix(6), id: \.id) { album in
                                GlobalSearchAlbumRow(album: album) {
                                    navigateToAlbum(album)
                                }
                            }
                        }
                    }
                    if !search.youtubeResults.isEmpty {
                        section(title: "YouTube", count: search.youtubeResults.count) {
                            ForEach(search.youtubeResults.prefix(8), id: \.id) { entry in
                                GlobalSearchYouTubeRow(entry: entry) {
                                    Task { await playYouTube(entry) }
                                }
                            }
                        }
                    }

                    if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("输入关键词搜索本地资料库和 YouTube")
                            .font(.callout)
                            .foregroundStyle(BrandColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if search.trackResults.isEmpty
                                && search.albumResults.isEmpty
                                && search.artistResults.isEmpty
                                && search.youtubeResults.isEmpty
                                && !search.isSearchingYouTube {
                        Text("无搜索结果")
                            .font(.callout)
                            .foregroundStyle(BrandColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(BrandColors.textSecondary)
                Text("\(count)").font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary.opacity(0.6))
                Spacer()
            }
            content()
        }
    }

    // MARK: - Actions

    private func close() {
        search.reset()
        isPresented = false
    }

    private func play(_ track: Track, from tracks: [Track]) {
        let snaps = tracks.map { TrackSnapshot(from: $0) }
        guard let snap = snaps.first(where: { $0.id == track.id }) else { return }
        playback.playTrack(snap, context: snaps, from: .search)
        close()
    }

    private func navigateToArtist(_ artist: Artist) {
        NotificationCenter.default.post(name: .musesNavigateArtist, object: artist)
        close()
    }

    private func navigateToAlbum(_ album: Album) {
        NotificationCenter.default.post(name: .musesNavigateAlbum, object: album)
        close()
    }

    private func playYouTube(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        guard let searchService = search.youTubeSearch else { return }
        do {
            let snap = try await searchService.importAsTrack(entry: entry)
            playback.playTrack(snap, context: [snap], from: .search)
        } catch {
            // 静默
        }
        close()
    }
}

// MARK: - Result rows

private struct GlobalSearchTrackRow: View {
    let track: Track
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                let hash = track.localArtworkHash ?? track.album?.artworkHash
                if let h = hash, let p = ArtworkCache.default.path(forHash: h) {
                    Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
                        .frame(width: 32, height: 32).cornerRadius(4).clipped()
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "music.note").font(.caption))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(String(format: "%d:%02d", Int(track.durationSeconds) / 60, Int(track.durationSeconds) % 60))
                    .font(.caption2).foregroundStyle(BrandColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchArtistRow: View {
    let artist: Artist
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(BrandColors.surface).frame(width: 32, height: 32)
                    if let h = artist.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
                        Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
                            .frame(width: 32, height: 32).clipShape(Circle())
                    } else {
                        Image(systemName: "person.2.fill").font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }
                Text(artist.name).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchAlbumRow: View {
    let album: Album
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let h = album.artworkHash, let p = ArtworkCache.default.path(forHash: h) {
                    Image(nsImage: NSImage(byReferencing: p)).resizable().scaledToFill()
                        .frame(width: 32, height: 32).cornerRadius(4).clipped()
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(BrandColors.surface)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "music.note").font(.caption))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(album.albumArtist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct GlobalSearchYouTubeRow: View {
    let entry: YTDlpBridge.YTDlpPlaylistEntry
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { Rectangle().fill(BrandColors.surface) }
                }
                .frame(width: 56, height: 32).cornerRadius(4).clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                    Text(entry.uploader ?? "YouTube").font(.caption)
                        .foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle").foregroundStyle(BrandColors.magenta)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

// MARK: - Navigation notifications

extension Notification.Name {
    static let musesNavigateArtist = Notification.Name("muses.navigateArtist")
    static let musesNavigateAlbum = Notification.Name("muses.navigateAlbum")
}