import SwiftUI

/// Existing playback and pre-download preferences, presented without a wall of copy.
struct PlaybackSettingsView: View {
    @Environment(StreamPrecacheService.self) private var precache
    @AppStorage(PrefKey.streamPrecacheEnabled) private var precacheEnabled = false
    @AppStorage(PrefKey.streamPrecacheScope) private var scope = "favorites"
    @AppStorage(PrefKey.streamPrecacheLimitGB) private var cacheLimit = 2
    @AppStorage(PrefKey.resumeAfterVideo) private var resumeAfterVideo = true

    var body: some View {
        Section {
            Toggle(tr("Resume after video", "视频关闭后续播"), isOn: $resumeAfterVideo)
        } header: { Text(tr("Playback", "播放")) }
        Section {
            SettingsExplainedToggle(title: tr("Prepare while idle", "空闲时预下载"), isOn: $precacheEnabled,
                information: tr("Off by default. Prepares up to 200 songs when playback is idle and pauses when you play. Existing cache is retained; new downloads stop at the budget.",
                                "默认关闭。空闲时最多准备 200 首，播放时暂停。保留已有缓存，达到容量后停止新增下载。"))
            DisclosureGroup(tr("Scope & capacity", "范围与容量")) {
                Picker(tr("Scope", "范围"), selection: $scope) {
                    Text(tr("Favorites", "收藏歌曲")).tag("favorites")
                    Text(tr("Previously played", "听过的歌曲")).tag("recent")
                    Text(tr("Both", "收藏及听过的歌曲")).tag("both")
                }
                .pickerStyle(.menu)
                .disabled(!precacheEnabled)
                Picker(tr("Capacity", "容量"), selection: $cacheLimit) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!precacheEnabled)
                LabeledContent(tr("Status", "状态"), value: precache.status)
                    .font(MusesTypography.caption)
            }
        } header: { Text(tr("Pre-download", "预下载")) }
        .onChange(of: precacheEnabled) { _, _ in precache.configure() }
        .onChange(of: scope) { _, _ in precache.configure() }
        .onChange(of: cacheLimit) { _, _ in precache.configure() }
    }
}
