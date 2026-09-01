import SwiftUI

/// Listening history is a local, useful dashboard rather than a raw event log.
/// It distinguishes loading, empty, and persistence failure explicitly.
struct HistoryView: View {
    @Environment(HistoryService.self) private var history
    @Environment(LibraryService.self) private var library
    @Environment(PlaybackService.self) private var playback
    @AppStorage(PrefKey.ffSmartHistory) private var enabled = true
    @State private var range: RecapRange = .week
    @State private var dashboard: ListeningHistoryDashboard?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var showClearConfirm = false

    private let metricColumns = [
        GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppleMusicSpacing.section) {
                header
                if enabled {
                    content
                } else {
                    disabledState
                }
            }
            .padding(.horizontal, AppleMusicTokens.contentPaddingX)
            .padding(.top, AppleMusicSpacing.browseTitleTop)
            .padding(.bottom, OverlayChromeMetrics.scrollBottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrowseBackground())
        .task { reload() }
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: history.historyRevision) { _, _ in reload() }
        .confirmationDialog(
            tr("Clear all listening history?", "清空全部收听历史？"),
            isPresented: $showClearConfirm
        ) {
            Button(tr("Clear", "清空"), role: .destructive) { clearHistory() }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(tr(
                "This removes the listening activity stored on this Mac.",
                "这会移除此 Mac 上保存的收听活动。"
            ))
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("History", "历史"))
                    .font(.system(size: AppleMusicTokens.pageTitleSize, weight: .heavy))
                    .foregroundStyle(BrandColors.textPrimary)
                Text(tr(
                    "Your listening rhythm, favorites, and recent activity — private to this Mac.",
                    "你的收听节奏、偏好和最近活动，仅保存在此 Mac。"
                ))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            if dashboard?.totalEventCount ?? 0 > 0 {
                ChromeIconButton(
                    systemName: "trash",
                    help: tr("Clear history", "清空历史"),
                    accessibility: tr("Clear listening history", "清空收听历史")
                ) { showClearConfirm = true }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, dashboard == nil {
            ProgressView(tr("Loading listening history…", "正在载入收听历史…"))
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if let loadError {
            errorState(loadError)
        } else if let dashboard, dashboard.totalEventCount > 0 {
            if dashboard.recap.eventCount > 0 {
                dashboardContent(dashboard)
            } else {
                rangeEmptyState
            }
        } else {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: tr("Nothing played yet", "还没有播放记录"),
                subtitle: tr(
                    "Play a song and its listening activity will appear here.",
                    "播放歌曲后，其收听活动会显示在这里。"
                )
            )
        }
    }

    private func dashboardContent(_ value: ListeningHistoryDashboard) -> some View {
        VStack(alignment: .leading, spacing: AppleMusicSpacing.section) {
            HStack {
                Text(tr("Listening overview", "收听概览"))
                    .font(.system(size: AppleMusicTokens.sectionTitleSize, weight: .bold))
                Spacer()
                Picker("", selection: $range) {
                    ForEach(RecapRange.allCases, id: \.self) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 330)
                .accessibilityLabel(tr("History range", "历史时间范围"))
            }

            metricGrid(value.recap)
            ListeningHeatmapView(heatmap: value.heatmap)
            topLists(value.recap)
            recentActivity(value.recent, range: value.recap.rangeLabel)
        }
    }

    private func metricGrid(_ recap: ListeningRecap) -> some View {
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
            HistoryMetricCard(
                value: ListeningFormat.duration(recap.totalListenedMs),
                label: tr("Time listened", "收听时长")
            )
            HistoryMetricCard(
                value: "\(recap.uniqueTracks)",
                label: tr("Different songs", "不同歌曲")
            )
            HistoryMetricCard(
                value: "\(recap.uniqueArtists)",
                label: tr("Artists", "艺术家")
            )
            HistoryMetricCard(
                value: completionLabel(recap),
                label: tr("Finished plays", "完整播放")
            )
        }
    }

    private func topLists(_ recap: ListeningRecap) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                rankingCard(
                    title: tr("Songs on repeat", "循环热歌"),
                    rows: recap.topTracks.prefix(5).map {
                        ($0.title, $0.artist, tr("\($0.plays) plays", "播放 \($0.plays) 次"))
                    }
                )
                rankingCard(
                    title: tr("Top artists", "热门艺术家"),
                    rows: recap.topArtists.prefix(5).map {
                        ($0.name, ListeningFormat.duration($0.listenedMs), tr("\($0.plays) plays", "播放 \($0.plays) 次"))
                    }
                )
            }
            VStack(spacing: 16) {
                rankingCard(
                    title: tr("Songs on repeat", "循环热歌"),
                    rows: recap.topTracks.prefix(5).map {
                        ($0.title, $0.artist, tr("\($0.plays) plays", "播放 \($0.plays) 次"))
                    }
                )
                rankingCard(
                    title: tr("Top artists", "热门艺术家"),
                    rows: recap.topArtists.prefix(5).map {
                        ($0.name, ListeningFormat.duration($0.listenedMs), tr("\($0.plays) plays", "播放 \($0.plays) 次"))
                    }
                )
            }
        }
    }

    private func rankingCard(title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 14)
            if rows.isEmpty {
                Text(tr("Not enough listening activity yet", "收听活动还不够多"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(index == 0 ? BrandColors.magenta : BrandColors.textSecondary)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(row.1).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        Text(row.2)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    .padding(.vertical, 9)
                    if index < rows.count - 1 { Divider().padding(.leading, 36) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColors.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        )
    }

    private func recentActivity(_ events: [ListeningEventSnapshot], range: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Recent activity · \(range)", "最近活动 · \(range)"))
                .font(.system(size: AppleMusicTokens.sectionTitleSize, weight: .bold))
            LazyVStack(spacing: 2) {
                ForEach(events) { event in
                    let track = library.track(by: event.trackId)
                    HStack(spacing: 12) {
                        ArtworkView(
                            source: track.map(ArtworkSource.resolve(for:)) ?? .placeholder,
                            cornerRadius: 5,
                            glyphSize: 16,
                            targetSize: 44
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(event.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(event.startedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                        Text(ListeningFormat.duration(event.listenedMs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(BrandColors.textSecondary)
                            .frame(width: 60, alignment: .trailing)
                        Button { play(event, within: events) } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(BrandColors.magenta)
                        .frame(width: 28, height: 28)
                        .disabled(track == nil)
                        .help(track == nil
                              ? tr("This song is no longer in the library", "这首歌曲已不在资料库中")
                              : tr("Play", "播放"))
                        .accessibilityLabel(tr("Play \(event.title)", "播放 \(event.title)"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        playback.state.track?.id == event.trackId
                            ? BrandColors.magenta.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("History could not be loaded", "无法载入历史记录"))
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
            Button(tr("Try Again", "重试")) { reload() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColors.surface.opacity(0.65),
            in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        )
    }

    private var rangeEmptyState: some View {
        EmptyStateView(
            icon: "calendar.badge.clock",
            title: tr("No listening in \(range.label)", "\(range.label) 暂无收听记录"),
            subtitle: tr(
                "Choose another range to explore earlier listening activity.",
                "可切换时间范围查看更早的收听活动。"
            )
        )
    }

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Listening history is off", "收听历史已关闭"))
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            Text(tr(
                "Turn it on in Settings to keep play, skip, and stop activity on this Mac.",
                "在设置中开启后，播放、跳过和停止活动会保存在此 Mac。"
            ))
            .font(.callout)
            .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BrandColors.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        )
    }

    private func reload() {
        guard enabled else {
            isLoading = false
            dashboard = nil
            loadError = nil
            return
        }
        isLoading = true
        do {
            dashboard = try history.dashboard(range: range)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func clearHistory() {
        do {
            try history.clearAllReporting()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        reload()
    }

    private func play(_ event: ListeningEventSnapshot, within events: [ListeningEventSnapshot]) {
        let context = events.compactMap { library.track(by: $0.trackId) }
            .reduce(into: [TrackSnapshot]()) { result, track in
                guard !result.contains(where: { $0.id == track.id }) else { return }
                result.append(TrackSnapshot(from: track))
            }
        guard let selected = context.first(where: { $0.id == event.trackId }) else { return }
        playback.playTrack(selected, context: context, from: .recently)
    }

    private func completionLabel(_ recap: ListeningRecap) -> String {
        guard recap.eventCount > 0 else { return "—" }
        let percent = Int((Double(recap.completedCount) / Double(recap.eventCount) * 100).rounded())
        return "\(percent)%"
    }
}

private struct HistoryMetricCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(BrandColors.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(
            BrandColors.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: AppleMusicTokens.cardCorner, style: .continuous)
        )
    }
}

enum ListeningFormat {
    static func duration(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
