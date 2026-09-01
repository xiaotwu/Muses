import SwiftUI

/// 导入 YouTube 歌单链接的 sheet:粘贴 URL + 导入按钮 + 进度态。
struct YouTubeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
    let onImport: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Import YouTube Playlist", "导入 YouTube 歌单")).font(.title2).fontWeight(.bold)
                .foregroundStyle(BrandColors.textPrimary)

            TextField("https://www.youtube.com/playlist?list=PL...",
                      text: $url)
                .textFieldStyle(.roundedBorder)

            Text(tr("Supports YouTube playlist links (with list= parameter). Importing is for personal use only, comply with YouTube's Terms of Service and local laws.", "支持 YouTube 歌单链接(含 list= 参数)。导入仅个人使用,遵守 YouTube 服务条款与当地法律。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)

            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                Button(tr("Import", "导入")) {
                    onImport(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.magenta)
                .disabled(url.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .musesFloatingChrome(cornerRadius: 16)
    }
}