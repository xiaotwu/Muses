import SwiftUI

/// 统一的「添加音乐」菜单,从工具栏 `+` 按钮展开(spec §1)。
///
/// 合并过去分散的入口:
///  - Paste YouTube Link —— 粘贴 YouTube 链接,自动识别单曲/歌单(`AddYouTubeLinkSheet`)。
///  - Add Local Folder —— 添加本地资料库文件夹(复用既有 `ImportSheet`)。
struct AddMusicMenu: View {
    @Binding var showLocalFolder: Bool
    @Binding var showYouTubeLink: Bool

    var body: some View {
        Menu {
            Button {
                showYouTubeLink = true
            } label: {
                Label(tr("Paste YouTube Link", "粘贴 YouTube 链接"), systemImage: "play.rectangle")
            }
            Button {
                showLocalFolder = true
            } label: {
                Label(tr("Add Local Folder", "添加本地文件夹"), systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(tr("Add Music", "添加音乐"))
    }
}

/// 粘贴 YouTube 链接的 sheet:自动识别单曲 / 歌单。
///
/// - 含 `list=` 参数 → 调 `importService.importPlaylist(url:)`。
/// - 否则识别为单曲(`watch?v=` / `youtu.be/` / `shorts/` / `embed/`)→ 调 `importService.importVideo(url:)`。
struct AddYouTubeLinkSheet: View {
    @Environment(YouTubeImportService.self) private var importService
    @Environment(\.dismiss) private var dismiss
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
                Button(tr("Cancel", "取消")) { dismiss() }.disabled(importing)
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
        .background(.ultraThinMaterial)
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
                dismiss()
            } catch let err {
                importing = false
                error = "\(err.localizedDescription)"
            }
        }
    }
}

/// YouTube 链接种类识别(纯函数,可单测)。
enum YouTubeLinkKind {
    case video, playlist, unknown

    static func detect(_ raw: String) -> YouTubeLinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed) else { return .unknown }

        // 歌单:任意带 list= 参数的 YouTube 链接。
        if let items = comps.queryItems,
           let list = items.first(where: { $0.name == "list" })?.value,
           !list.isEmpty {
            return .playlist
        }

        let host = (comps.host ?? "").lowercased()
        let isYouTube = host.hasSuffix("youtube.com") || host == "youtu.be"
        guard isYouTube else { return .unknown }

        // 单曲:watch?v= / youtu.be/<id> / shorts/<id> / embed/<id>。
        if comps.host == "youtu.be", comps.path.count > 1 { return .video }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return .video
        }
        let path = comps.path.lowercased()
        if path.hasPrefix("/shorts/") || path.hasPrefix("/embed/") { return .video }

        // 无 list= 的 /playlist 链接缺歌单 id,视为未知。
        return .unknown
    }
}