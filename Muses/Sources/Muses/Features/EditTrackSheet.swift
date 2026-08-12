import SwiftUI

/// 编辑曲目元数据表单。仅修改 DB,不写文件标签(个人使用)。
struct EditTrackSheet: View {
    let track: Track
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var albumTitle = ""
    @State private var albumArtist = ""
    @State private var trackNo = ""
    @State private var discNo = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var lyrics = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("编辑信息").font(.headline).foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button("取消") { dismiss() }
                    .foregroundStyle(BrandColors.textSecondary)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.cyan)
            }
            .padding(16)

            Divider().background(BrandColors.hairline)

            Form {
                Section("基本信息") {
                    TextField("标题", text: $title)
                    TextField("艺术家", text: $artist)
                    TextField("专辑", text: $albumTitle)
                    TextField("专辑艺术家", text: $albumArtist)
                }
                Section("曲目信息") {
                    TextField("曲目号", text: $trackNo)
                    TextField("碟号", text: $discNo)
                    TextField("年份", text: $year)
                    TextField("流派", text: $genre)
                }
                Section("歌词") {
                    TextEditor(text: $lyrics)
                        .font(.caption)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(BrandColors.background)
        .frame(width: 480)
        .frame(maxHeight: 560)
        .onAppear { loadFields() }
    }

    private func loadFields() {
        title = track.title
        artist = track.artist
        albumTitle = track.albumTitle ?? ""
        albumArtist = track.albumArtist ?? ""
        trackNo = track.trackNo.map(String.init) ?? ""
        discNo = track.discNo.map(String.init) ?? ""
        year = track.year.map(String.init) ?? ""
        genre = track.genre ?? ""
        lyrics = track.lyrics ?? ""
    }

    private func save() {
        library.updateTrack(
            id: track.id,
            title: title,
            artist: artist,
            albumTitle: albumTitle.isEmpty ? nil : albumTitle,
            albumArtist: albumArtist.isEmpty ? nil : albumArtist,
            trackNo: Int(trackNo),
            discNo: Int(discNo),
            year: Int(year),
            genre: genre.isEmpty ? nil : genre,
            lyrics: lyrics.isEmpty ? nil : lyrics
        )
        dismiss()
    }
}