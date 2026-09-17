import SwiftUI

private enum QueueFocusTarget: Hashable {
    case drawer
}

/// Integrated trailing pane showing Current Queue / Up Next / History.
/// The current queue and Up Next support drag reordering (`.onMove`); History is read-only.
struct QueueDrawerView: View {
    @Environment(PlaybackService.self) private var playback
    @Binding var isPresented: Bool
    var showsScrim: Bool = true
    /// Advanced Queue flag off: keep the existing UI (grouping, history labels, restore, and remove are hidden).
    @AppStorage(PrefKey.ffAdvancedQueue) private var advancedQueue = true
    /// Target group id and draft text for the rename-group alert.
    @State private var renameTarget: QueueGroup.ID?
    @State private var renameText = ""
    /// Queue has no search field; keep the drawer itself key-focusable so
    /// Escape reaches `.onKeyPress` the way Search's focused field does.
    @FocusState private var focusedTarget: QueueFocusTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if showsScrim {
                BrandColors.scrim
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
            }
            drawer
                .frame(width: QueueChromePolicy.width)
                .frame(maxHeight: .infinity)
                .musesGlass(in: SidebarPaneShape.trailingShape, role: .persistentChrome)
                .clipShape(SidebarPaneShape.trailingShape)
                .focusable()
                .focused($focusedTarget, equals: .drawer)
                .onKeyPress(.escape) {
                    guard renameTarget == nil else { return .ignored }
                    isPresented = false
                    return .handled
                }
                .transition(.move(edge: .trailing))
        }
        .onExitCommand { dismissUnlessRenaming() }
        .onAppear { focusedTarget = .drawer }
        .onChange(of: renameTarget) { _, target in
            focusedTarget = target == nil ? .drawer : nil
        }
        .animation(MusesMotion.drawerAnimation(reduceMotion: reduceMotion), value: isPresented)
    }

    private func dismissUnlessRenaming() {
        if renameTarget == nil { isPresented = false }
    }

    private var repeatAccessibilityValue: String {
        switch playback.queue.repeatMode {
        case .off: return tr("Off", "关闭")
        case .one: return tr("One song", "单曲")
        case .all: return tr("Current queue", "当前队列")
        }
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            header
            Toggle(isOn: Binding(get: { playback.queue.smartShuffle.enabled },
                                 set: { playback.setSmartShuffle($0) })) {
                Label(tr("Smart Shuffle", "智能随机播放", zhHant: "智慧隨機播放"), systemImage: "sparkles")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .help(tr("After three collection songs, insert at most one YouTube Music recommendation. Play Next takes priority.",
                     "每播放三首集合歌曲，最多插入一首 YouTube Music 推荐。手动下一首优先。",
                     zhHant: "每播放三首集合歌曲，最多插入一首 YouTube Music 推薦。手動下一首優先。"))
            list
        }
    }

    private var header: some View {
        HStack {
            Text(tr("Playing Next", "接下来播放"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BrandColors.textPrimary)
            Spacer()
            // Repeat mode cycle
            Button {
                playback.queue.setRepeat(playback.queue.repeatMode.next)
            } label: {
                Image(systemName: playback.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(playback.queue.repeatMode == .off
                             ? BrandColors.textSecondary : BrandColors.accent)
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(playback.queue.repeatMode == .off ? Color.clear : BrandColors.accent.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(playback.queue.repeatMode == .off ? Color.clear : BrandColors.accent.opacity(0.25), lineWidth: 1))
            .help(tr("Repeat mode", "循环模式"))
            .accessibilityLabel(tr("Repeat mode", "循环模式"))
            .accessibilityValue(repeatAccessibilityValue)

            // Shuffle toggle
            Button {
                playback.queue.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(playback.queue.shuffle
                             ? BrandColors.accent : BrandColors.textSecondary)
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(playback.queue.shuffle ? BrandColors.accent.opacity(0.12) : Color.clear, in: Circle())
            .overlay(Circle().stroke(playback.queue.shuffle ? BrandColors.accent.opacity(0.25) : Color.clear, lineWidth: 1))
            .help(tr("Shuffle", "随机播放"))
            .accessibilityLabel(tr("Shuffle", "随机播放"))
            .accessibilityValue(playback.queue.shuffle ? tr("On", "开启") : tr("Off", "关闭"))

            // Advanced Queue: create a group (flag on only), auto-named "Group N";
            // renaming happens through an inline alert (text field) on the group row.
            if advancedQueue {
                Button {
                    let n = playback.queue.groups.count + 1
                    playback.queue.addGroup(tr("Group \(n)", "分组 \(n)", zhHant: "分組 \(n)"))
                } label: {
                    Image(systemName: "rectangle.group.badge.plus")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(BrandColors.textSecondary)
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .help(tr("Add group", "新建分组"))
                .accessibilityLabel(tr("Add group", "新建分组"))
            }

            ChromeIconButton(
                systemName: "xmark",
                help: tr("Close", "关闭"),
                accessibility: tr("Close queue", "关闭队列")
            ) { isPresented = false }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var list: some View {
        List {
            // Advanced Queue: group management (collapse / rename / delete).
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
                            }
                            .buttonStyle(.plain)
                            .help(group.collapsed ? tr("Expand group", "展开分组")
                                                  : tr("Collapse group", "折叠分组"))
                            .accessibilityLabel(group.collapsed
                                ? tr("Expand \(group.name)", "展开 \(group.name)", zhHant: "展開 \(group.name)")
                                : tr("Collapse \(group.name)", "折叠 \(group.name)", zhHant: "折疊 \(group.name)"))
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

            Section(tr("History", "历史记录")) {
                ForEach(playback.queue.history) { item in
                    QueueRow(item: item, isCurrent: false, showHistoryBadge: advancedQueue)
                        .queueRowActions {
                            TrackContextMenuItems(
                                snapshot: item.track,
                                onPlay: {
                                    playback.playTrack(
                                        item.track,
                                        context: [item.track],
                                        from: item.fromContext
                                    )
                                }
                            )
                            if advancedQueue {
                                Divider()
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

            if let item = playback.queue.insertedCurrent {
                Section(tr("Now Playing", "正在播放", zhHant: "正在播放")) {
                    QueueRow(item: item, isCurrent: true)
                        .queueRowActions {
                            TrackContextMenuItems(snapshot: item.track, onPlay: { playback.toggle() })
                        }
                }
            }

            Section(tr("Current Queue", "当前队列")) {
                ForEach(visibleQueueItems) { item in
                    QueueRow(item: item,
                             isCurrent: playback.queue.current()?.id == item.id,
                             showHistoryBadge: advancedQueue)
                        .queueRowActions { itemContextMenu(for: item, inUpNext: false) }
                        .onTapGesture(count: 2) { playQueueItem(item) }
                }
                .onMove { indices, destination in
                    guard playback.queue.groups.allSatisfy({ !$0.collapsed }) else { return }
                    guard let from = indices.first else { return }
                    playback.queue.move(from: from,
                                        to: destination > from ? destination - 1 : destination)
                }
            }
            Section(tr("Up Next", "下一首")) {
                ForEach(playback.queue.upNext) { item in
                    QueueRow(item: item, isCurrent: false, showHistoryBadge: advancedQueue)
                        .queueRowActions { itemContextMenu(for: item, inUpNext: true) }
                        .onTapGesture(count: 2) { playQueueItem(item) }
                }
                .onMove { indices, destination in
                    guard let from = indices.first else { return }
                    playback.queue.moveUpNext(from: from,
                                              to: destination > from ? destination - 1 : destination)
                }
            }
            if let recommendation = playback.queue.smartShuffle.pending {
                Section(tr("YouTube Music recommendation", "YouTube Music 推荐", zhHant: "YouTube Music 推薦")) {
                    QueueRow(item: recommendation, isCurrent: false, showHistoryBadge: false)
                        .contextMenu {
                            Button(tr("Play Next", "下一首播放", zhHant: "下一首播放")) {
                                playback.queue.playNext(recommendation.track)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .listRowSeparator(.visible)
        .scrollContentBackground(.hidden)
        .background(.clear)
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

    /// Hide members of collapsed groups, except the currently playing row.
    private var visibleQueueItems: [QueueItem] {
        let collapsed = Set(playback.queue.groups.filter(\.collapsed).map(\.id))
        guard !collapsed.isEmpty else { return playback.queue.items }
        let currentID = playback.queue.current()?.id
        return playback.queue.items.filter { item in
            guard let gid = item.groupId, collapsed.contains(gid) else { return true }
            return item.id == currentID
        }
    }

    /// Number of entries in items + upNext that belong to a given group.
    private func itemsInGroup(_ id: QueueGroup.ID) -> Int {
        playback.queue.items.filter { $0.groupId == id }.count
        + playback.queue.upNext.filter { $0.groupId == id }.count
    }

    /// Queue rows always expose useful track actions. Advanced Queue adds the
    /// lock and grouping operations without turning the basic menu into an empty shell.
    @ViewBuilder
    private func itemContextMenu(for item: QueueItem, inUpNext: Bool) -> some View {
        TrackContextMenuItems(
            snapshot: item.track,
            onPlay: { playQueueItem(item) },
            showsPlayNext: false,
            showsAddToQueue: false
        )
        if advancedQueue {
            Divider()
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
        }
        if canRemove(item: item, inUpNext: inUpNext) {
            Divider()
            Button(tr("Remove", "移除"), role: .destructive) {
                if inUpNext, let idx = playback.queue.upNext.firstIndex(where: { $0.id == item.id }) {
                    playback.queue.removeUpNext(at: idx)
                } else if !inUpNext, let idx = playback.queue.items.firstIndex(where: { $0.id == item.id }) {
                    playback.queue.removeItem(at: idx)
                }
            }
        }
    }

    private func playQueueItem(_ item: QueueItem) {
        let context = playback.queue.items.map(\.track) + playback.queue.upNext.map(\.track)
        playback.playTrack(
            item.track,
            context: context.isEmpty ? [item.track] : context,
            from: item.fromContext
        )
    }

    private func canRemove(item: QueueItem, inUpNext: Bool) -> Bool {
        if inUpNext { return true }
        guard let index = playback.queue.items.firstIndex(where: { $0.id == item.id }) else {
            return false
        }
        return index != playback.queue.currentIndex
    }

    /// Assigns an item to a group (rewrites items/upNext in place and persists).
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
            ArtworkView(source: ArtworkSource.resolve(for: item.track), cornerRadius: 5,
                        glyphSize: 16, targetSize: 36)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent || (showHistoryBadge && item.historyState != nil) {
                        Image(systemName: leadingIcon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(leadingTint)
                            .padding(3)
                            .background(BrandColors.surface, in: Circle())
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? BrandColors.accent : BrandColors.textPrimary)
                    .lineLimit(1)
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
            Color.clear.frame(width: 24, height: 28)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }

    /// Current playback uses play.fill; history entries get an icon from their state label; otherwise music.note.
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
        if isCurrent { return BrandColors.accent }
        if showHistoryBadge, let s = item.historyState {
            switch s {
            case .played: return BrandColors.textSecondary
            case .skipped: return BrandColors.textSecondary
            case .removed: return BrandColors.textSecondary
            }
        }
        return BrandColors.textSecondary
    }


}

private extension View {
    /// Pointer menus and visible actions expose the same complete track operations.
    func queueRowActions<Actions: View>(@ViewBuilder _ actions: @escaping () -> Actions) -> some View {
        self.contextMenu(menuItems: actions)
            .overlay(alignment: .trailing) {
                Menu(content: actions) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .tint(BrandColors.textSecondary)
                .help(tr("Track options", "曲目选项", zhHant: "曲目選項"))
                .accessibilityLabel(tr("Track options", "曲目选项", zhHant: "曲目選項"))
            }
            .listRowBackground(Color.clear)
    }
}
