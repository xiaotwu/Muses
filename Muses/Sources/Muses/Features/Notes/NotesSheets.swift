import SwiftUI

/// 曲目笔记 + 书签编辑 sheet(Final Spec §10.7 Feature 7)。
/// 上半:曲目笔记(TextEditor,upsert,空→删行)。下半:书签列表(按时间升序),可加/改/删,
/// 展示当前播放位置快速加书签。功能开关 ffNotes 关时仅可读不可写(按钮禁用)。
struct TrackNotesSheet: View {
    let track: Track
    @Environment(NotesService.self) private var notes
    @Environment(\.dismiss) private var dismiss

    @State private var noteText: String = ""
    @State private var bookmarks: [TrackBookmark] = []
    @State private var newBookmarkTitle: String = ""
    @State private var editingBookmark: TrackBookmark?
    @State private var editTitle: String = ""
    @State private var editNote: String = ""

    private var enabled: Bool { notes.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline)
                    Text(track.artist).font(.caption).foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
                Button(tr("Done", "完成")) { dismiss() }
            }
            Divider()

            // 曲目笔记
            Text(tr("Note", "笔记")).font(.subheadline).foregroundStyle(BrandColors.textSecondary)
            TextEditor(text: $noteText)
                .font(.body)
                .frame(minHeight: 100)
                .padding(6)
                .background(BrandColors.surface)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BrandColors.hairline, lineWidth: 1))
                .disabled(!enabled)

            // 书签
            HStack {
                Text(tr("Bookmarks", "书签")).font(.subheadline).foregroundStyle(BrandColors.textSecondary)
                Spacer()
                Button {
                    addBookmarkAtEnd()
                } label: { Label(tr("Add", "添加"), systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(!enabled)
            }
            if bookmarks.isEmpty {
                Text(tr("No bookmarks", "无书签")).font(.caption).foregroundStyle(BrandColors.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(bookmarks, id: \.id) { bm in
                    bookmarkRow(bm)
                }
            }

            // 新书签标题输入
            HStack {
                TextField(tr("Bookmark title (optional)", "书签标题(可选)"), text: $newBookmarkTitle)
                    .textFieldStyle(.roundedBorder)
                Button {
                    addBookmarkAtEnd()
                } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(BrandColors.magenta)
                    .disabled(!enabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .frame(minHeight: 420)
        .onAppear { reload() }
        .sheet(item: $editingBookmark) { bm in
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Edit Bookmark", "编辑书签")).font(.headline)
                TextField(tr("Title", "标题"), text: $editTitle).textFieldStyle(.roundedBorder)
                TextField(tr("Note", "笔记"), text: $editNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...6)
                HStack {
                    Spacer()
                    Button(tr("Cancel", "取消")) { editingBookmark = nil }
                    Button(tr("Save", "保存")) { saveEdit(bm) }.buttonStyle(.borderedProminent)
                }
            }
            .padding(20).frame(width: 380)
        }
    }

    private func reload() {
        noteText = notes.note(forTrack: track.id)?.content ?? ""
        bookmarks = notes.bookmarks(forTrack: track.id)
    }

    private func bookmarkRow(_ bm: TrackBookmark) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill").foregroundStyle(BrandColors.magenta)
            Text(formatTimestamp(bm.timestampMs)).font(.callout)
                .foregroundStyle(BrandColors.textPrimary).monospacedDigit()
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(bm.title ?? "").font(.caption).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                if let n = bm.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Button { editingBookmark = bm; editTitle = bm.title ?? ""; editNote = bm.note ?? "" } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
            Button { deleteBookmark(bm) } label: {
                Image(systemName: "trash")
            }.buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func addBookmarkAtEnd() {
        let ts = bookmarks.last?.timestampMs ?? 0
        let title = newBookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = notes.addBookmark(trackId: track.id, timestampMs: ts, title: title.isEmpty ? nil : title, note: nil)
        newBookmarkTitle = ""
        reload()
    }

    private func saveEdit(_ bm: TrackBookmark) {
        notes.updateBookmark(id: bm.id,
                             title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editTitle,
                             note: editNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editNote)
        editingBookmark = nil
        reload()
    }

    private func deleteBookmark(_ bm: TrackBookmark) {
        notes.removeBookmark(id: bm.id)
        reload()
    }

    private func formatTimestamp(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

/// Now Playing 右栏书签列表(Final Spec §10.7):点击书签跳转到该时间戳。
/// 仅当当前曲目有书签时渲染;无书签不占空间。
struct BookmarksView: View {
    let trackId: UUID
    @Environment(NotesService.self) private var notes
    @Environment(PlaybackService.self) private var playback

    var body: some View {
        let bms = notes.bookmarks(forTrack: trackId)
        let _ = notes.revision
        if !bms.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Bookmarks", "书签"))
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(BrandColors.textSecondary)
                ForEach(bms, id: \.id) { bm in
                    Button {
                        playback.seek(to: bm.timestampMs)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2).foregroundStyle(BrandColors.magenta)
                            Text(format(bm.timestampMs)).font(.caption).monospacedDigit()
                                .foregroundStyle(BrandColors.textPrimary)
                            if let t = bm.title, !t.isEmpty {
                                Text(t).font(.caption).foregroundStyle(BrandColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(BrandColors.surface.opacity(0.6))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
