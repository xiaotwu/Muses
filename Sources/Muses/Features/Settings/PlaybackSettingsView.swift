import SwiftUI

/// Playback settings that the playback layer actually reads.
struct PlaybackSettingsView: View {
    @Environment(StreamPrecacheService.self) private var precache
    @AppStorage(PrefKey.streamPrecacheEnabled) private var precacheEnabled = false
    @AppStorage(PrefKey.streamPrecacheScope) private var scope = "favorites"
    @AppStorage(PrefKey.streamPrecacheLimitGB) private var cacheLimit = 2
    @AppStorage(PrefKey.resumeAfterVideo) private var resumeAfterVideo: Bool = true

    var body: some View {
        Section {
            Toggle(isOn: $resumeAfterVideo) {
                Text(tr("Resume music when video closes", "关闭视频后继续播放音乐"))
                    .foregroundStyle(BrandColors.textPrimary)
            }
            .tint(BrandColors.accent)
        } header: { Text(tr("Playback", "播放")).font(MusesTypography.headline.weight(.semibold)) }
        Section {
            Toggle(tr("Prepare songs while playback is idle", "播放空闲时预下载歌曲"), isOn: $precacheEnabled)
                .tint(BrandColors.accent)
            Picker(tr("Songs to prepare", "预下载范围"), selection: $scope) {
                Text(tr("Favorites", "收藏歌曲")).tag("favorites")
                Text(tr("Previously played", "听过的歌曲")).tag("recent")
                Text(tr("Favorites and previously played", "收藏及听过的歌曲")).tag("both")
            }
            .disabled(!precacheEnabled)
            Picker(tr("Stream cache budget", "音频缓存容量限制"), selection: $cacheLimit) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) GB").tag($0) }
            }
            .disabled(!precacheEnabled)
            Text(tr("Off by default. Prepares up to 200 songs when playback is idle and pauses when you play. Existing cache is retained; new downloads stop at the budget.",
                    "默认关闭。播放空闲时准备最多 200 首歌曲，开始播放时暂停。保留已有缓存，达到容量限制后停止新增预下载。"))
                .font(MusesTypography.caption).foregroundStyle(BrandColors.textSecondary)
            LabeledContent(tr("Status", "状态"), value: precache.status)
        } header: { Text(tr("Optional song preparation", "可选歌曲预下载")).font(MusesTypography.headline.weight(.semibold)) }
        .onChange(of: precacheEnabled) { _, _ in precache.configure() }
        .onChange(of: scope) { _, _ in precache.configure() }
        .onChange(of: cacheLimit) { _, _ in precache.configure() }
    }
}
