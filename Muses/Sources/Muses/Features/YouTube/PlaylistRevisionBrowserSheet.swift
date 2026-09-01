import SwiftUI

struct PlaylistRevisionBrowserSheet: View {
    @Environment(YouTubePlaylistSyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss

    let importID: UUID
    let playlistTitle: String

    @State private var revisions: [YouTubePlaylistRevisionSummary] = []
    @State private var selectedRevisionID: UUID?
    @State private var comparisonRevisionID: UUID?
    @State private var comparison: YouTubePlaylistRevisionComparison?
    @State private var pendingRestoreID: UUID?
    @State private var errorMessage: String?
    @State private var notice: String?

    private var selectedRevision: YouTubePlaylistRevisionSummary? {
        revisions.first { $0.id == selectedRevisionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                revisionList
                    .frame(minWidth: 300, idealWidth: 340)
                revisionDetail
                    .frame(minWidth: 420, idealWidth: 520)
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 560, idealHeight: 640)
        .background(BrandColors.background)
        .task { reload() }
        .alert(tr("Restore this version locally?", "要在本地恢复此版本吗？"),
               isPresented: Binding(
                get: { pendingRestoreID != nil },
                set: { if !$0 { pendingRestoreID = nil } }
               )) {
            Button(tr("Cancel", "取消"), role: .cancel) { pendingRestoreID = nil }
            Button(tr("Restore Locally", "恢复到本地")) { restorePendingRevision() }
        } message: {
            Text(tr("A recovery point is saved first. YouTube is never changed.",
                    "系统会先保存恢复点，且绝不会修改 YouTube。"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Version History", "版本历史"))
                    .font(.title2.weight(.semibold))
                Text(playlistTitle)
                    .font(.callout)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            Label(tr("Local only", "仅限本地"), systemImage: "externaldrive.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColors.textSecondary)
                .help(tr("Restore actions never push changes to YouTube",
                         "恢复操作绝不会将更改推送到 YouTube"))
            ChromeIconButton(systemName: "xmark", help: tr("Close", "关闭"),
                             accessibility: tr("Close version history", "关闭版本历史")) {
                dismiss()
            }
        }
        .padding(18)
    }

    private var revisionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Recovery Points", "恢复点"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            if revisions.isEmpty {
                ContentUnavailableView(
                    tr("No Recovery Points", "暂无恢复点"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(tr("Changes and sync checks will create recoverable versions.",
                                         "变更与同步检查会创建可恢复版本。")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(revisions) { revision in
                            revisionRow(revision)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(BrandColors.surface.opacity(0.45))
    }

    private func revisionRow(_ revision: YouTubePlaylistRevisionSummary) -> some View {
        let selected = selectedRevisionID == revision.id
        return HStack(spacing: 10) {
            Button {
                selectedRevisionID = revision.id
                updateComparison()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: revisionSymbol(revision.kind))
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22)
                        .foregroundStyle(selected ? BrandColors.magenta : BrandColors.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(revisionLabel(revision.kind))
                            .font(.callout.weight(.semibold))
                        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    Spacer()
                    Text(tr("\(revision.itemCount) songs", "\(revision.itemCount) 首"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(BrandColors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr(
                "\(revisionLabel(revision.kind)), \(revision.itemCount) songs, \(revision.createdAt.formatted(date: .complete, time: .shortened))",
                "\(revisionLabel(revision.kind))，\(revision.itemCount) 首，\(revision.createdAt.formatted(date: .complete, time: .shortened))"))

            Button {
                togglePin(revision)
            } label: {
                Image(systemName: revision.pinned ? "pin.fill" : "pin")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(revision.pinned ? tr("Unpin version", "取消固定版本")
                                  : tr("Pin version", "固定版本"))
            .accessibilityLabel(revision.pinned ? tr("Unpin version", "取消固定版本")
                                                : tr("Pin version", "固定版本"))
        }
        .padding(10)
        .background(selected ? BrandColors.magenta.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(BrandColors.magenta.opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var revisionDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedRevision {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(revisionLabel(selectedRevision.kind))
                            .font(.title3.weight(.semibold))
                        Text(selectedRevision.createdAt.formatted(date: .long, time: .standard))
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                    Spacer()
                    Picker(tr("Compare with", "比较版本"), selection: $comparisonRevisionID) {
                        Text(tr("No comparison", "不比较")).tag(Optional<UUID>.none)
                        ForEach(revisions.filter { $0.id != selectedRevision.id }) { revision in
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .tag(Optional(revision.id))
                        }
                    }
                    .frame(width: 250)
                    .onChange(of: comparisonRevisionID) { _, _ in updateComparison() }
                }

                if let comparison {
                    comparisonSummary(comparison)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if comparison.changes.isEmpty {
                                ContentUnavailableView(
                                    tr("No Ordered Changes", "顺序内容无变化"),
                                    systemImage: "equal",
                                    description: Text(tr("These versions contain the same ordered occurrences.",
                                                         "这两个版本包含相同的有序条目。")))
                            } else {
                                ForEach(comparison.changes) { change in
                                    changeRow(change)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        tr("Select a Version to Compare", "选择要比较的版本"),
                        systemImage: "arrow.left.arrow.right",
                        description: Text(tr("Inserted, removed, and moved occurrences are shown in order.",
                                             "将按顺序显示新增、移除和移动的条目。")))
                }
            } else {
                ContentUnavailableView(tr("Select a Recovery Point", "选择恢复点"),
                                       systemImage: "clock.arrow.circlepath")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func comparisonSummary(_ comparison: YouTubePlaylistRevisionComparison) -> some View {
        HStack(spacing: 14) {
            Label("+\(comparison.insertedCount)", systemImage: "plus.circle")
            Label("−\(comparison.removedCount)", systemImage: "minus.circle")
            Label("↕︎\(comparison.movedCount)", systemImage: "arrow.up.arrow.down.circle")
            Spacer()
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(BrandColors.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr(
            "\(comparison.insertedCount) inserted, \(comparison.removedCount) removed, \(comparison.movedCount) moved",
            "新增 \(comparison.insertedCount) 项，移除 \(comparison.removedCount) 项，移动 \(comparison.movedCount) 项"))
    }

    private func changeRow(_ change: YouTubePlaylistRevisionChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: changeSymbol(change.kind))
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.item.knownTitle ?? tr("Unknown Title", "未知标题"))
                    .font(.callout.weight(.medium))
                Text(changeDescription(change))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
        }
        .padding(10)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                    .lineLimit(2)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            } else {
                Text(tr("Restores are local and never push to YouTube.",
                        "恢复仅在本地进行，绝不会推送到 YouTube。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }
            Spacer()
            Button(tr("Restore as Copy", "恢复为副本")) { restoreSelectedAsCopy() }
                .disabled(selectedRevisionID == nil)
            Button(tr("Restore Current", "恢复当前歌单")) {
                pendingRestoreID = selectedRevisionID
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandColors.magenta)
            .disabled(selectedRevisionID == nil)
        }
        .padding(14)
    }

    private func reload(selecting selection: UUID? = nil) {
        do {
            revisions = try sync.revisionSummaries(importID: importID)
            selectedRevisionID = selection ?? selectedRevisionID ?? revisions.first?.id
            if comparisonRevisionID == selectedRevisionID {
                comparisonRevisionID = nil
            }
            errorMessage = nil
            updateComparison()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePin(_ revision: YouTubePlaylistRevisionSummary) {
        do {
            try sync.setRevisionPinned(revisionID: revision.id, pinned: !revision.pinned)
            reload(selecting: revision.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateComparison() {
        guard let selectedRevisionID, let comparisonRevisionID else {
            comparison = nil
            return
        }
        do {
            let selectedDate = revisions.first { $0.id == selectedRevisionID }?.createdAt ?? .distantPast
            let otherDate = revisions.first { $0.id == comparisonRevisionID }?.createdAt ?? .distantPast
            comparison = try selectedDate <= otherDate
                ? sync.compareRevisions(olderID: selectedRevisionID, newerID: comparisonRevisionID)
                : sync.compareRevisions(olderID: comparisonRevisionID, newerID: selectedRevisionID)
            errorMessage = nil
        } catch {
            comparison = nil
            errorMessage = error.localizedDescription
        }
    }

    private func restorePendingRevision() {
        guard let id = pendingRestoreID else { return }
        do {
            try sync.restore(revisionID: id)
            notice = tr("Playlist restored locally; a recovery point was saved.",
                        "歌单已在本地恢复，并已保存恢复点。")
            errorMessage = nil
            pendingRestoreID = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            pendingRestoreID = nil
        }
    }

    private func restoreSelectedAsCopy() {
        guard let id = selectedRevisionID else { return }
        do {
            _ = try sync.restoreAsCopy(revisionID: id)
            notice = tr("Recovered copy created in Muses Playlists.",
                        "已在 Muses 歌单中创建恢复副本。")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revisionLabel(_ kind: YouTubePlaylistRevisionKind) -> String {
        switch kind {
        case .base: return tr("Accepted Base", "已接受基线")
        case .local: return tr("Local Snapshot", "本地快照")
        case .remoteShadow: return tr("Remote Check", "远端检查")
        case .remotePartial: return tr("Incomplete Remote", "未完成远端")
        case .beforePull: return tr("Before Pull", "拉取前")
        case .beforePush: return tr("Before Push", "推送前")
        case .beforeDelete: return tr("Before Delete", "删除前")
        case .beforeRestore: return tr("Before Restore", "恢复前")
        case .restored: return tr("Restored", "已恢复")
        }
    }

    private func revisionSymbol(_ kind: YouTubePlaylistRevisionKind) -> String {
        switch kind {
        case .remoteShadow, .remotePartial: return "icloud.and.arrow.down"
        case .beforePull: return "arrow.down.circle"
        case .beforePush: return "arrow.up.circle"
        case .beforeDelete: return "trash.slash"
        case .beforeRestore: return "arrow.uturn.backward.circle"
        case .restored: return "checkmark.circle"
        case .base: return "checkmark.seal"
        case .local: return "internaldrive"
        }
    }

    private func changeSymbol(_ kind: YouTubePlaylistRevisionChangeKind) -> String {
        switch kind {
        case .inserted: return "plus.circle"
        case .removed: return "minus.circle"
        case .moved: return "arrow.up.arrow.down.circle"
        }
    }

    private func changeDescription(_ change: YouTubePlaylistRevisionChange) -> String {
        switch change.kind {
        case .inserted:
            return tr("Inserted at \((change.toPosition ?? 0) + 1)",
                      "新增至第 \((change.toPosition ?? 0) + 1) 位")
        case .removed:
            return tr("Removed from \((change.fromPosition ?? 0) + 1)",
                      "从第 \((change.fromPosition ?? 0) + 1) 位移除")
        case .moved:
            return tr("Moved \((change.fromPosition ?? 0) + 1) → \((change.toPosition ?? 0) + 1)",
                      "从第 \((change.fromPosition ?? 0) + 1) 位移至第 \((change.toPosition ?? 0) + 1) 位")
        }
    }
}
