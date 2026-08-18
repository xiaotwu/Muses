import SwiftUI
import SwiftData

/// 收听历史浏览面(Final Spec §10.3 Feature 3 — Smart Listening History 的 UI)。
///
/// 独立组件,不改动 `PlayerBar`/`NowPlayingView` 等共享面。功能开关
/// `PrefKey.ffSmartHistory`:关闭时显示引导态(去设置开启),不显示历史数据。
/// 通过 `HistoryService.historyRevision` 触发重算(@Observable)。
struct HistoryView: View {
    @Environment(HistoryService.self) private var history
    @Environment(PlaybackService.self) private var playback
    @AppStorage(PrefKey.ffSmartHistory) private var enabled = false
    @State private var range: RecapRange = .week
    @State private var outcomeFilter: ListeningOutcome? = nil
    @State private var search: String = ""
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if enabled {
                    recapCard
                    filterBar
                    eventList
                } else {
                    disabledState
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrandColors.background)
        .navigationSubtitle(enabled ? tr("Listening History", "收听历史") : "")
        .confirmationDialog(tr("Clear all listening history?", "清空全部收听历史?"),
                            isPresented: $showClearConfirm) {
            Button(tr("Clear", "清空"), role: .destructive) { history.clearAll() }
            Button(tr("Cancel", "取消"), role: .cancel) {}
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Listening History", "收听历史"))
                .font(.largeTitle.bold())
                .foregroundStyle(BrandColors.textPrimary)
            Text(tr("Every play, skip and stop — recorded locally.",
                    "每一次播放、跳过与停止 —— 本地记录。"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    // MARK: - 回顾卡

    private var recapCard: some View {
        let _ = history.historyRevision   // 订阅落库计数器,触发重算
        let recap = history.recap(range: range)
        return VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $range) {
                ForEach(RecapRange.allCases, id: \.self) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 24) {
                stat(tr("Listening time", "收听时长"), ListeningFormat.duration(recap.totalListenedMs))
                stat(tr("Plays", "播放次数"), "\(recap.eventCount)")
                stat(tr("Completed", "播完"), "\(recap.completedCount)")
                stat(tr("Skipped", "跳过"), "\(recap.skippedCount)")
            }

            HStack(spacing: 24) {
                stat(tr("Unique songs", "不同曲目"), "\(recap.uniqueTracks)")
                stat(tr("Unique artists", "不同艺术家"), "\(recap.uniqueArtists)")
                stat(tr("Local", "本地"), ListeningFormat.duration(recap.localMs))
                stat(tr("YouTube", "YouTube"), ListeningFormat.duration(recap.youtubeMs))
            }

            if !recap.topTracks.isEmpty {
                tallyList(tr("Top songs", "最常听"),
                          recap.topTracks.map { "\($0.title) — \($0.artist)" })
            }
            if !recap.topArtists.isEmpty {
                tallyList(tr("Top artists", "热门艺术家"),
                          recap.topArtists.map { "\($0.name)" })
            }
        }
        .padding(20)
        .background(BrandColors.surface)
        .cornerRadius(12)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func tallyList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(BrandColors.textSecondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 过滤 + 事件列表

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(tr("Search title or artist", "搜索标题或艺术家"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Picker("", selection: $outcomeFilter) {
                    Text(tr("All outcomes", "全部结局")).tag(ListeningOutcome?.none)
                    Text(tr("Completed", "播完")).tag(ListeningOutcome?.some(.completed))
                    Text(tr("Skipped", "跳过")).tag(ListeningOutcome?.some(.skipped))
                    Text(tr("Stopped", "停止")).tag(ListeningOutcome?.some(.stopped))
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label(tr("Clear", "清空"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var eventList: some View {
        let _ = history.historyRevision
        let events = history.events(matching: HistoryQuery(
            titleContains: search, artistContains: search, outcome: outcomeFilter, limit: 200))
        return VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                Text(tr("No events match.", "没有匹配的记录。"))
                    .font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(events.enumerated()), id: \.element.id) { _, ev in
                    eventRow(ev)
                    Divider().overlay(BrandColors.hairline)
                }
            }
        }
    }

    private func eventRow(_ ev: ListeningEvent) -> some View {
        HStack(spacing: 12) {
            outcomeBadge(ev.outcome)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.trackTitle)
                    .font(.callout)
                    .foregroundStyle(BrandColors.textPrimary)
                    .lineLimit(1)
                Text("\(ev.artist) · \(ev.source == .youtube ? "YouTube" : tr("Local", "本地"))")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ListeningFormat.duration(ev.listenedMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(BrandColors.textPrimary)
                Text(ev.startedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { replay(ev) }
    }

    private func outcomeBadge(_ o: ListeningOutcome) -> some View {
        let (icon, tint): (String, Color) = {
            switch o {
            case .completed: return ("checkmark.circle.fill", BrandColors.magenta)
            case .skipped:   return ("forward.fill", BrandColors.textSecondary)
            case .stopped:   return ("stop.fill", BrandColors.textSecondary)
            case .interrupted: return ("exclamationmark.triangle.fill", BrandColors.textSecondary)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(tint)
            .frame(width: 20)
    }

    private func replay(_ ev: ListeningEvent) {
        // 仅本地仍存在的曲目可即时重放;YouTube/已删除曲目静默跳过(不伪造可用)。
        guard ev.source == .local else { return }
        let trackId = ev.trackId
        guard let track = (try? ModelContext(history.container)
                            .fetch(FetchDescriptor<Track>(
                                predicate: #Predicate { $0.id == trackId })))?.first
        else { return }
        let snap = TrackSnapshot(from: track)
        playback.playTrack(snap, context: [snap], from: .recently)
    }

    // MARK: - 未启用态

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Listening history is off", "收听历史已关闭"),
                  systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(BrandColors.textPrimary)
            Text(tr("Enable it in Settings → Listening to record every play, skip and stop. Records stay on this Mac.",
                    "在「设置 → 收听」中开启即可记录每一次播放、跳过与停止。数据仅保存在本机。"))
                .font(.callout)
                .foregroundStyle(BrandColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.surface)
        .cornerRadius(12)
    }
}

/// 历史展示用的时长格式化。
enum ListeningFormat {
    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return "\(m)m \(r)s" }
        let h = m / 60, mr = m % 60
        return "\(h)h \(mr)m"
    }
}