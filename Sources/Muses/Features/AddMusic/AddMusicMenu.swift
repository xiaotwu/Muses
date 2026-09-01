import SwiftUI

/// Add-music control. YouTube links only — local folders are not part of the product.
struct AddMusicMenu: View {
    @Binding var showYouTubeLink: Bool

    var body: some View {
        Button {
            showYouTubeLink = true
        } label: {
            YouTubeMark(size: 16)
        }
        .buttonStyle(.plain)
        .help(tr("Paste YouTube Link", "粘贴 YouTube 链接"))
        .accessibilityLabel(tr("Add YouTube music", "添加 YouTube 音乐"))
    }
}

/// Sheet for pasting a YouTube link: auto-detects single video vs. playlist.
///
/// - With a `list=` parameter → calls `importService.importPlaylist(url:)`.
/// - Otherwise detected as a single video (`watch?v=` / `youtu.be/` / `shorts/` / `embed/`) → calls `importService.importVideo(url:)`.
struct AddYouTubeLinkSheet: View {
    @Environment(YouTubeImportService.self) private var importService
    @Environment(\.dismiss) private var dismiss
    var isPresented: Binding<Bool>? = nil
    @State private var url: String = ""
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Paste YouTube Link", "粘贴 YouTube 链接"))
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)

            TextField("https://www.youtube.com/watch?v=…  /  …/playlist?list=…",
                      text: $url, axis: .horizontal)
                .textFieldStyle(.roundedBorder)
                .disabled(importing)

            Text(detectedHint)
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            Text(tr("Auto-detected: single video or playlist. Importing is for personal use only, comply with YouTube's Terms of Service and local laws.",
                    "自动识别:单曲或歌单。导入仅个人使用,遵守 YouTube 服务条款与当地法律。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            if let err = error {
                Text(err).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { close() }.disabled(importing)
                Button(tr("Import", "导入")) { performImport() }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColors.magenta)
                    .disabled(url.isEmpty || importing || detectedKind == nil)
                    .overlay {
                        if importing { ProgressView().controlSize(.small) }
                    }
            }
        }
        .padding(20)
        .frame(width: 480)
        .musesFloatingChrome(cornerRadius: 16)
    }

    private enum DetectedKind { case video, playlist }

    private var detectedKind: DetectedKind? {
        YouTubeLinkKind.detect(url) == .playlist ? .playlist
            : (YouTubeLinkKind.detect(url) == .video ? .video : nil)
    }

    private var detectedHint: String {
        switch detectedKind {
        case .video: return tr("Detected: single video", "识别为:单曲")
        case .playlist: return tr("Detected: playlist", "识别为:歌单")
        case nil: return url.isEmpty ? "" : tr("Unrecognized link", "无法识别的链接")
        }
    }

    private func performImport() {
        importing = true
        error = nil
        Task {
            do {
                switch YouTubeLinkKind.detect(url) {
                case .playlist:
                    _ = try await importService.importPlaylist(url: url)
                case .video:
                    _ = try await importService.importVideo(url: url)
                case .unknown:
                    throw YouTubeImportError.invalidURL
                }
                importing = false
                close()
            } catch let err {
                importing = false
                error = "\(err.localizedDescription)"
            }
        }
    }

    private func close() {
        if let isPresented {
            isPresented.wrappedValue = false
        } else {
            dismiss()
        }
    }
}

/// YouTube link-kind detection (pure function, unit-testable).
enum YouTubeLinkKind {
    case video, playlist, unknown

    static func detect(_ raw: String) -> YouTubeLinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed) else { return .unknown }

        // Playlist: any YouTube link with a list= parameter.
        if let items = comps.queryItems,
           let list = items.first(where: { $0.name == "list" })?.value,
           !list.isEmpty {
            return .playlist
        }

        let host = (comps.host ?? "").lowercased()
        let isYouTube = host.hasSuffix("youtube.com") || host == "youtu.be"
        guard isYouTube else { return .unknown }

        // Single video: watch?v= / youtu.be/<id> / shorts/<id> / embed/<id>.
        if comps.host == "youtu.be", comps.path.count > 1 { return .video }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return .video
        }
        let path = comps.path.lowercased()
        if path.hasPrefix("/shorts/") || path.hasPrefix("/embed/") { return .video }

        // A /playlist link without list= has no playlist id; treat it as unknown.
        return .unknown
    }
}
