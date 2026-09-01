import SwiftUI

/// Track metadata editing form. Modifies the DB only; never writes file tags (personal use).
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
            // Header
            HStack {
                Text(tr("Edit Info", "编辑信息")).font(.headline).foregroundStyle(BrandColors.textPrimary)
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                    .foregroundStyle(BrandColors.textSecondary)
                Button(tr("Save", "保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
            }
            .padding(16)

            Divider().background(BrandColors.hairline)

            Form {
                Section(tr("Basic Info", "基本信息")) {
                    TextField(tr("Title", "标题"), text: $title)
                    TextField(tr("Artist", "艺术家"), text: $artist)
                    TextField(tr("Album", "专辑"), text: $albumTitle)
                    TextField(tr("Album Artist", "专辑艺术家"), text: $albumArtist)
                }
                Section(tr("Track Info", "曲目信息")) {
                    TextField(tr("Track No.", "曲目号"), text: $trackNo)
                    TextField(tr("Disc No.", "碟号"), text: $discNo)
                    TextField(tr("Year", "年份"), text: $year)
                    TextField(tr("Genre", "流派"), text: $genre)
                }
                Section(tr("Lyrics", "歌词")) {
                    TextEditor(text: $lyrics)
                        .font(.caption)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .musesFloatingChrome(cornerRadius: 16)
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
