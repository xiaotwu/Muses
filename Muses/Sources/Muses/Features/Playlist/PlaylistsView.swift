import SwiftUI
import SwiftData

/// 歌单列表页:展示所有歌单 + 新建/删除。
struct PlaylistsView: View {
    @Environment(PlaylistService.self) private var playlistService
    @Binding var selectedPlaylist: Playlist?
    @State private var playlists: [Playlist] = []
    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if playlists.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "暂无歌单",
                                   subtitle: "点击右上角 + 创建歌单")
                } else {
                    ForEach(playlists, id: \.id) { playlist in
                        PlaylistCard(playlist: playlist,
                                     onTap: { selectedPlaylist = playlist },
                                     onDelete: { deletePlaylist(playlist) })
                    }
                }
            }
            .padding(16)
        }
        .background(BrandColors.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showCreateSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            VStack(spacing: 16) {
                Text("新建歌单").font(.headline)
                TextField("歌单名称", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { showCreateSheet = false; newPlaylistName = "" }
                    Button("创建") {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            playlistService.create(name: name)
                            refresh()
                        }
                        showCreateSheet = false
                        newPlaylistName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 320)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        playlists = playlistService.fetchAll()
    }

    private func deletePlaylist(_ playlist: Playlist) {
        playlistService.delete(playlist)
        refresh()
    }
}

/// 单个歌单卡片。
struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: () -> Void
    let onDelete: () -> Void
    @Environment(PlaylistService.self) private var playlistService

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // 歌单封面占位
                RoundedRectangle(cornerRadius: 8)
                    .fill(BrandColors.surface)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(BrandColors.cyan)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name).font(.headline).foregroundStyle(BrandColors.textPrimary)
                    Text("\(playlist.items?.count ?? 0) 首")
                        .font(.caption).foregroundStyle(BrandColors.textSecondary)
                }

                Spacer()
            }
            .padding(12)
            .background(BrandColors.surface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除歌单", role: .destructive, action: onDelete)
        }
    }
}