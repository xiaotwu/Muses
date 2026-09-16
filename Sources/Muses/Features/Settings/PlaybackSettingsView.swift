import SwiftUI

/// Playback settings that the playback layer actually reads.
struct PlaybackSettingsView: View {
    @AppStorage(PrefKey.resumeAfterVideo) private var resumeAfterVideo: Bool = true

    var body: some View {
        Section {
            Toggle(isOn: $resumeAfterVideo) {
                Text(tr("Resume music when video closes", "关闭视频后继续播放音乐"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.accent)
        } header: { Text(tr("Playback", "播放")).font(.headline.weight(.semibold)) }
    }
}
