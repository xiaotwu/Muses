import SwiftUI

/// On-demand chapter lookup; no per-row network work or new playback authority.
struct YouTubeChaptersView: View {
    let videoID: String
    let seek: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ytDlpBridge) private var bridge
    @State private var chapters: [YouTubeChapter] = []
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Chapters", "章节", zhHant: "章節")).font(.headline)
                Spacer()
                Button(tr("Close", "关闭", zhHant: "關閉"), systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .help(tr("Close", "关闭", zhHant: "關閉"))
            }
            if loading {
                ProgressView().accessibilityLabel(tr("Loading chapters", "正在加载章节", zhHant: "正在載入章節"))
                    .frame(maxWidth: .infinity)
            } else if failed {
                HStack {
                    Text(tr("Chapters could not be loaded.", "无法加载章节。", zhHant: "無法載入章節。"))
                    Spacer()
                    Button(tr("Retry", "重试", zhHant: "重試"), systemImage: "arrow.clockwise") { retry += 1 }
                        .labelStyle(.iconOnly)
                        .help(tr("Retry", "重试", zhHant: "重試"))
                }
            } else if chapters.isEmpty {
                Text(tr("No chapters are available for this video.", "此视频没有可用章节。", zhHant: "此影片沒有可用章節。"))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(chapters) { chapter in
                            Button { seek(chapter.start) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(chapter.title).lineLimit(2)
                                    Spacer()
                                    Text(timestamp(chapter.start)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(tr("Jump to chapter", "跳到章节", zhHant: "跳至章節"))
                        }
                    }
                }.frame(maxHeight: 320)
            }
        }
        .padding(16).frame(width: 340)
        .onExitCommand { dismiss() }
        .task(id: "\(videoID):\(retry)") {
            loading = true
            failed = false
            chapters = []
            do {
                guard let bridge else { throw YTDlpBridge.YTDlpError.notFound }
                let result = try await bridge.fetchChapters(videoId: videoID)
                try Task.checkCancellation()
                chapters = result
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                loading = false
            }
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(min(seconds, Double(Int.max / 2)))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
