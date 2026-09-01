import SwiftUI
import SwiftData

/// 收件箱浏览面(Final Spec §10.6 Feature 6 — Music Inbox 的 UI)。
///
/// 独立侧边栏区段,不改动 `PlayerBar`/`NowPlayingView`。功能开关 `PrefKey.ffInbox`:
/// 关闭时显示引导态(去设置开启)。用 `@Query` 自动响应 `InboxItem` 落库变化。
struct InboxView: View {
    @Environment(InboxService.self) private var inbox
    @Environment(PlaybackService.self) private var playback
    @Environment(LibraryService.self) private var library
    @AppStorage(PrefKey.ffInbox) private var enabled = true
    @Query(sort: \InboxItem.addedAt, order: .reverse) private var items: [InboxItem]
    @State private var noteTarget: InboxItem.ID?
    @State private var noteText = ""

    private var pending: [InboxItem] { items.filter { $0.state == .unheard || $0.state == .listening } }
    private var snoozed: [InboxItem] { items.filter { $0.state == .snoozed } }
    private var decided: [InboxItem] { items.filter { $0.state == .accepted || $0.state == .rejected } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if enabled {
                    pendingSection
                    if !snoozed.isEmpty { snoozedSection }
                    if !decided.isEmpty { decidedSummary }
                    if items.isEmpty { emptyState }
                } else {
                    disabledState
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrowseBackground())
        .onAppear { if enabled { inbox.restoreDueSnoozes() } }
        .alert(tr("Add note", "添加备注"), isPresented: Binding(
            get: { noteTarget != nil },
            set: { if !$0 { noteTarget = nil } })) {
            TextField(tr("Note", "备注"), text: $noteText)
            Button(tr("Save", "保存")) {
                if let id = noteTarget { inbox.addNote(id: id, note: noteText) }
                noteTarget = nil
            }
            Button(tr("Cancel", "取消"), role: .cancel) { noteTarget = nil }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Inbox", "收件箱"))
                .font(.largeTitle.bold()).foregroundStyle(BrandColors.textPrimary)
            Text(tr("Songs to revisit. Accept to like, reject to dismiss, snooze to defer.",
                    "待回看的曲目:接受即收藏,拒绝即忽略,延后再提醒。"))
                .font(.callout).foregroundStyle(BrandColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 待处理

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Pending", "待处理")).font(.headline).foregroundStyle(BrandColors.textPrimary)
            ForEach(pending) { item in inboxRow(item) }
            if pending.isEmpty { Text(tr("Nothing pending.", "无待处理项。")).font(.callout).foregroundStyle(BrandColors.textSecondary) }
        }
    }

    private var snoozedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Snoozed", "已延后")).font(.headline).foregroundStyle(BrandColors.textPrimary)
            ForEach(snoozed) { item in inboxRow(item) }
        }
    }

    private var decidedSummary: some View {
        Text(tr("\(decided.filter { $0.state == .accepted }.count) accepted · \(decided.filter { $0.state == .rejected }.count) rejected",
                "已接受 \(decided.filter { $0.state == .accepted }.count) · 已拒绝 \(decided.filter { $0.state == .rejected }.count)"))
            .font(.callout).foregroundStyle(BrandColors.textSecondary)
    }

    @ViewBuilder
    private func inboxRow(_ item: InboxItem) -> some View {
        HStack(spacing: 10) {
            stateBadge(item.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackTitle).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(BrandColors.textSecondary).lineLimit(1)
                if let note = item.notes, !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(BrandColors.textSecondary).lineLimit(2)
                }
            }
            Spacer()
            // 主操作:Play / Accept / Reject
            Button { play(item) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).foregroundStyle(BrandColors.magenta)
                .help(tr("Play", "播放"))
            Button { inbox.accept(id: item.id, library: library) } label: { Image(systemName: "checkmark") }
                .buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
                .help(tr("Accept", "接受"))
            Button { inbox.reject(id: item.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(BrandColors.textSecondary)
                .help(tr("Reject", "拒绝"))
            Menu {
                inboxMenuContent(for: item)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(BrandColors.textSecondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { inboxMenuContent(for: item) }
    }

    /// 收件箱行的菜单内容(右键菜单与「…」按钮共用,issue #2)。
    @ViewBuilder
    private func inboxMenuContent(for item: InboxItem) -> some View {
        Button(tr("Play Next", "下一首播放")) { playback.queue.playNext(snapshot(for: item)) }
        Button(tr("Add to Queue", "加入队列")) { playback.queue.addToQueue(snapshot(for: item)) }
        Divider()
        Menu(tr("Snooze", "延后")) {
            Button(tr("Later Today", "今晚")) { snooze(item, .laterToday) }
            Button(tr("Tomorrow", "明天")) { snooze(item, .tomorrow) }
            Button(tr("This Weekend", "本周末")) { snooze(item, .weekend) }
            Button(tr("Next Week", "下周")) { snooze(item, .nextWeek) }
        }
        Button(tr("Add note", "添加备注")) { noteTarget = item.id; noteText = item.notes ?? "" }
        Divider()
        Button(tr("Remove", "移除"), role: .destructive) { inbox.remove(id: item.id) }
    }

    // MARK: - 辅助

    private func stateBadge(_ s: InboxState) -> some View {
        let icon: String = {
            switch s {
            case .unheard: return "tray"
            case .listening: return "play.circle"
            case .accepted: return "checkmark.circle.fill"
            case .rejected: return "xmark.circle"
            case .snoozed: return "moon.zzz"
            }
        }()
        return Image(systemName: icon).font(.caption).foregroundStyle(BrandColors.textSecondary).frame(width: 16)
    }

    private func snapshot(for item: InboxItem) -> TrackSnapshot {
        TrackSnapshot(id: item.trackId, title: item.trackTitle, artist: item.artist,
                      albumTitle: item.albumTitle, durationSeconds: item.durationSeconds,
                      youTubeId: item.youTubeId,
                      artworkUrl: item.artworkUrl,
                      sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
    }

    private func play(_ item: InboxItem) {
        let snap = snapshot(for: item)
        playback.playTrack(snap, context: [snap], from: .recently)
    }

    private enum SnoozePreset { case laterToday, tomorrow, weekend, nextWeek }

    private func snooze(_ item: InboxItem, _ preset: SnoozePreset) {
        let cal = Calendar.current
        let now = Date()
        let until: Date
        switch preset {
        case .laterToday:
            until = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(4 * 3600)
        case .tomorrow:
            until = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now) ?? now
        case .weekend:
            let weekday = cal.component(.weekday, from: now)
            let daysToSat = (7 - weekday + 6) % 7  // 周六为 6
            let base = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
            until = cal.date(byAdding: .day, value: max(1, daysToSat), to: base) ?? now
        case .nextWeek:
            let weekday = cal.component(.weekday, from: now)
            let daysToMon = (8 - weekday + 1) % 7
            let base = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
            until = cal.date(byAdding: .day, value: max(1, daysToMon), to: base) ?? now
        }
        inbox.snooze(id: item.id, until: until)
    }

    private var emptyState: some View {
        Text(tr("Inbox is empty. Add songs from the PlayerBar “…” menu or a track’s context menu.",
                "收件箱为空。可在播放栏 “…” 菜单或曲目右键菜单中加入。"))
            .font(.callout).foregroundStyle(BrandColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Inbox is off", "收件箱已关闭"), systemImage: "tray")
                .font(.headline).foregroundStyle(BrandColors.textPrimary)
            Text(tr("Inbox is off. When it is on, accept to like, reject to dismiss, snooze to defer. Stays on this Mac.",
                    "收件箱已关闭。开启后:接受即收藏,拒绝即忽略,延后再提醒。数据仅保存在本机。"))
                .font(.callout).foregroundStyle(BrandColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.surface).cornerRadius(12)
    }
}
