import SwiftUI

enum YTAudioQualityOption: String, CaseIterable {
    case bestaudio, k256 = "256k", k128 = "128k", k64 = "64k"
    case best, p1080 = "1080p", p720 = "720p"

    var label: String {
        switch self {
        case .bestaudio: return tr("Best audio", "最高音质")
        case .k256: return tr("High (256k)", "高音质 (256k)")
        case .k128: return tr("Medium (128k)", "中等 (128k)")
        case .k64: return tr("Data saver (64k)", "省流 (64k)")
        case .best: return tr("Best video", "最高画质视频")
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    var isVideo: Bool {
        self == .best || self == .p1080 || self == .p720
    }
}

/// yt-dlp download quality + cache status. Changing quality reloads the current track.
struct AudioQualitySettingsView: View {
    @Environment(PlaybackService.self) private var playback
    @AppStorage(PrefKey.ytAudioQuality) private var ytQuality: String = "bestaudio"
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        Section(tr("Download Quality", "下载音质")) {
            if let q = playback.state.quality, playback.state.track != nil {
                LabeledContent(tr("Now playing", "正在播放")) {
                    Text(playingLabel(q))
                        .foregroundStyle(BrandColors.textPrimary)
                }
            }
            Picker(tr("Preferred quality", "首选音质"), selection: $ytQuality) {
                ForEach(YTAudioQualityOption.allCases, id: \.rawValue) { opt in
                    Text(opt.label).tag(opt.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: ytQuality) { _, _ in
                playback.reloadCurrent()
                cacheBytes = MediaFileCache.totalBytes()
            }
            Text(tr("yt-dlp caches each quality on disk. Switching quality re-downloads the current song.",
                    "yt-dlp 按音质缓存到本地。切换音质会重新下载当前曲目。"))
                .font(.caption).foregroundStyle(BrandColors.textSecondary)
        }

        Section(tr("Media cache", "媒体缓存")) {
            LabeledContent(tr("Size", "占用")) {
                Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
            }
            Button(tr("Clear cache", "清除缓存"), role: .destructive) {
                MediaFileCache.clearAll()
                cacheBytes = 0
                playback.reloadCurrent()
            }
        }
        .onAppear { cacheBytes = MediaFileCache.totalBytes() }
    }

    private func playingLabel(_ q: AudioQualityInfo) -> String {
        var parts: [String] = []
        if !q.codec.isEmpty { parts.append(q.codec) }
        if q.sampleRate > 0 { parts.append("\(q.sampleRate / 1000) kHz") }
        if q.bitDepth > 0 { parts.append("\(q.bitDepth)-bit") }
        let chosen = YTAudioQualityOption(rawValue: ytQuality)?.label ?? ytQuality
        parts.append(chosen)
        return parts.joined(separator: " · ")
    }
}
