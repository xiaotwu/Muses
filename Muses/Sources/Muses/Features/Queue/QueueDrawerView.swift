import SwiftUI

/// 队列抽屉:从 trailing 滑入,展示当前队列 / Up Next / History 三段。
/// 当前队列与 Up Next 支持拖拽重排(`.onMove`),History 只读。
struct QueueDrawerView: View {
    @Environment(PlaybackService.self) private var playback
    @Binding var isPresented: Bool
    /// Phase 19 Advanced Queue:关闭时维持既有 UI(分组/历史标签/还原/移除均隐藏)。
    @AppStorage(PrefKey.ffAdvancedQueue) private var advancedQueue = true
    /// 重命名分组 alert 的目标分组 id 与临时文本。
    @State private var renameTarget: QueueGroup.ID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            // 点击左侧遮罩关闭
            BrandColors.scrim
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            drawer
                .frame(width: 360)
                .musesGlass(in: Rectangle())
                .overlay(Rectangle().frame(width: 1).foregroundStyle(BrandColors.hairline),
                         alignment: .leading)
                .transition(.move(edge: .trailing))
        }
        .onExitCommand { isPresented = false }
        .animation(.easeInOut(duration: 0.25), value: isPresented)
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            header
            Divider().background(BrandColors.hairline)
            list
        }
    }

    private var header: some View {
        HStack {
            Text(tr("Queue", "队列")).font(.headline).foregroundStyle(BrandColors.textPrimary)
            Spacer()
            // Repeat 模式循环
            Button {
                let next: RepeatMode
                switch playback.queue.repeatMode {
                case .off:  next = .all
                case .all:  next = .one
                case .one:  next = .off
                }
                playback.queue.setRepeat(next)
            } label: {
                Image(systemName: playback.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.callout)
            }
            .foregroundStyle(playback.queue.repeatMode == .off
                             ? BrandColors.textSecondary : BrandColors.magenta)
            .buttonStyle(.plain)
            .help(tr("Repeat mode", "循环模式"))

            // Shuffle 切换
            Button {
                playback.queue.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.callout)
            }
            .foregroundStyle(playback.queue.shuffle
                             ? BrandColors.magenta : BrandColors.textSecondary)
            .buttonStyle(.plain)
            .help(tr("Shuffle", "随机播放"))

            // Phase 19:新建分组(仅 Advanced Queue 开启时),自动命名 "Group N";
            // 重命名通过分组行内 alert(textField)完成。
            if advancedQueue {
                Button {
                    let n = playback.queue.groups.count + 1
                    playback.queue.addGroup(tr("Group \(n)", "分组 \(n)"))
                } label: {
                    Image(systemName: "rectangle.group.badge.plus")
                        .font(.callout)
                }
                .foregroundStyle(BrandColors.textSecondary)
                .buttonStyle(.plain)
                .help(tr("Add group", "新建分组"))
            }

            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List {
            // Phase 19:分组管理(仅 Advanced Queue)。折叠/重命名/删除。
            if advancedQueue, !playback.queue.groups.isEmpty {
                Section(tr("Groups", "分组")) {
                    ForEach(playback.queue.groups) { group in
                        HStack {
                            Button {
                                playback.queue.toggleCollapsed(groupId: group.id)
                            } label: {
                                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(BrandColors.textSecondary)
                                    .frame(width: 14)
                            }.buttonStyle(.plain)
                            Text(group.name).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                            Spacer()
                            Text("\(itemsInGroup(group.id))")
                                .font(.caption2).foregroundStyle(BrandColors.textSecondary)
                        }
                        .contextMenu {
                            Button(tr("Rename", "重命名")) {
                                renameTarget = group.id
                                renameText = group.name
                            }
                            Button(tr("Delete group", "删除分组"), role: .destructive) {
                                playback.queue.removeGroup(id: group.id)
                            }
                        }
                    }
                }
            }

            Section(tr("Current Queue", "当前队列")) {
                ForEach(playback.queue.items) { item in
                    QueueRow(item: item,
                             isCurrent: playback.queue.currentIndex ==
                                        playback.queue.items.firstIndex(where: { $0.id == item.id }),
                             showHistoryBadge: advancedQueue)
                        .contextMenu { itemContextMenu(for: item, inUpNext: false) }
                }
                .onMove { indices, destination in
                    guard let from = indices.first else { return }
                    playback.queue.move(from: from,
                                        to: destination > from ? destination - 1 : destination)
                }
            }
            Section(tr("Up Next", "下一首")) {
                ForEach(playback.queue.upNext) { item in
                    QueueRow(item: item, isCurrent: false, showHistoryBadge: advancedQueue)
                        .contextMenu { itemContextMenu(for: item, inUpNext: true) }
                }
                .onMove { indices, destination in
                    guard let from = indices.first else { return }
                    playback.queue.moveUpNext(from: from,
                                              to: destination > from ? destination - 1 : destination)
                }
            }
            Section(tr("History", "历史记录")) {
                ForEach(playback.queue.history) { item in
                    QueueRow(item: item, isCurrent: false, showHistoryBadge: advancedQueue)
                        .contextMenu {
                            if advancedQueue {
                                Button(tr("Replay", "重新播放")) {
                                    playback.playTrack(item.track, context: [item.track], from: .songs)
                                }
                                Button(tr("Restore to queue", "还原到队列")) {
                                    if let idx = playback.queue.history.firstIndex(where: { $0.id == item.id }) {
                                        playback.queue.restoreFromHistory(at: idx)
                                    }
                                }
                                Button(tr("Remove from history", "从历史移除"), role: .destructive) {
                                    if let idx = playback.queue.history.firstIndex(where: { $0.id == item.id }) {
                                        playback.queue.history.remove(at: idx)
                                        playback.queue.persist()
                                    }
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .alert(tr("Rename group", "重命名分组"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField(tr("Group name", "分组名"), text: $renameText)
            Button(tr("Rename", "重命名")) {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let id = renameTarget {
                    playback.queue.renameGroup(id: id, to: name)
                }
                renameTarget = nil
            }
            Button(tr("Cancel", "取消"), role: .cancel) { renameTarget = nil }
        }
    }

    /// items + upNext 中归属某分组的条目数。
    private func itemsInGroup(_ id: QueueGroup.ID) -> Int {
        playback.queue.items.filter { $0.groupId == id }.count
        + playback.queue.upNext.filter { $0.groupId == id }.count
    }

    /// items / upNext 条目的右键菜单(Advanced Queue):锁定 + 分组赋值 + 移除。
    @ViewBuilder
    private func itemContextMenu(for item: QueueItem, inUpNext: Bool) -> some View {
        if advancedQueue {
            Button(item.locked ? tr("Unlock", "解锁") : tr("Lock", "锁定")) {
                playback.queue.toggleLocked(itemId: item.id)
            }
            if !playback.queue.groups.isEmpty {
                Menu(tr("Move to group", "移入分组")) {
                    Button(tr("None", "无")) { setGroupId(item: item, to: nil) }
                    ForEach(playback.queue.groups) { g in
                        Button(g.name) { setGroupId(item: item, to: g.id) }
                    }
                }
            }
            Button(tr("Remove", "移除"), role: .destructive) {
                if inUpNext, let idx = playback.queue.upNext.firstIndex(where: { $0.id == item.id }) {
                    playback.queue.removeUpNext(at: idx)
                } else if !inUpNext, let idx = playback.queue.items.firstIndex(where: { $0.id == item.id }) {
                    playback.queue.removeItem(at: idx)
                }
            }
        }
    }

    /// 把 item 归入分组(在 items/upNext 中原地改写并持久化)。
    private func setGroupId(item: QueueItem, to gid: UUID?) {
        if let i = playback.queue.items.firstIndex(where: { $0.id == item.id }) {
            playback.queue.items[i].groupId = gid; playback.queue.persist()
        } else if let i = playback.queue.upNext.firstIndex(where: { $0.id == item.id }) {
            playback.queue.upNext[i].groupId = gid; playback.queue.persist()
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool
    var showHistoryBadge: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: leadingIcon)
                .font(.caption)
                .foregroundStyle(leadingTint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title).foregroundStyle(BrandColors.textPrimary).lineLimit(1)
                Text(item.track.artist)
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.locked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Text(format(item.track.durationSeconds))
                .font(.caption2)
                .foregroundStyle(BrandColors.textSecondary)
        }
        .padding(.vertical, 4)
    }

    /// 当前播放用 play.fill;历史条目按状态标签给图标;否则 music.note。
    private var leadingIcon: String {
        if isCurrent { return "play.fill" }
        if showHistoryBadge, let s = item.historyState {
            switch s {
            case .played: return "checkmark.circle"
            case .skipped: return "forward.end.fill"
            case .removed: return "trash"
            }
        }
        return "music.note"
    }
    private var leadingTint: Color {
        if isCurrent { return BrandColors.magenta }
        if showHistoryBadge, let s = item.historyState {
            switch s {
            case .played: return BrandColors.textSecondary
            case .skipped: return BrandColors.textSecondary
            case .removed: return BrandColors.textSecondary
            }
        }
        return BrandColors.textSecondary
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}