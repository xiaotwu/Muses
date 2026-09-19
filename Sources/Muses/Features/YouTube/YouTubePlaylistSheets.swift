import SwiftUI

struct AddToYouTubePlaylistSheet: View {
    let youTubeImport: YouTubeImport
    @Environment(\.dismiss) private var dismiss
    @Environment(YouTubeSearchService.self) private var searchService
    @Environment(YouTubeImportService.self) private var importService
    @Environment(YouTubePlaylistSyncService.self) private var playlistSync
    @State private var query = ""
    @State private var results: [YTDlpBridge.YTDlpPlaylistEntry] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Add to playlist", "添加到歌单"))
                    .font(.headline)
                Spacer()
                Button(tr("Close", "关闭"), systemImage: "xmark") { dismiss() }
                    .labelStyle(ActionIconLabelStyle())
                    .help(tr("Close", "关闭"))
            }
            TextField(tr("Search YouTube", "搜索 YouTube"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await runSearch() } }
            if searching { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            List(results, id: \.id) { entry in
                Button {
                    Task { await add(entry) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).foregroundStyle(BrandColors.textPrimary)
                        Text(entry.uploader ?? "")
                            .font(.caption)
                            .foregroundStyle(BrandColors.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(16)
        .frame(width: 420, height: 480)
        .musesFloatingChrome(cornerRadius: 16)
        .onTapGesture {}
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await searchService.search(query: q, limit: 12)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ entry: YTDlpBridge.YTDlpPlaylistEntry) async {
        do {
            _ = try playlistSync.saveLocalRevision(importID: youTubeImport.id)
            guard importService.addRemoteVideo(
                importId: youTubeImport.id,
                videoId: entry.id,
                title: entry.title,
                artist: entry.uploader ?? youTubeImport.channel,
                durationMs: Int((entry.duration ?? 0) * 1000)) else {
                throw YouTubeImportError.notFound
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaylistPullPreviewSheet: View {
    let preview: YouTubePullPreview
    let onApply: (YouTubePlaylistSnapshot?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedItems: [YouTubePlaylistItemSnapshot]
    @State private var resolvedConflictIDs: Set<String> = []

    init(preview: YouTubePullPreview,
         onApply: @escaping (YouTubePlaylistSnapshot?) -> Void) {
        self.preview = preview
        self.onApply = onApply
        _resolvedItems = State(initialValue:
            (preview.automaticResult ?? preview.local).normalizedItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Pull Preview", "拉取预览"))
                        .font(.title2.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(BrandColors.textSecondary)
                }
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
            }

            if !preview.mergePlan.conflicts.isEmpty {
                Text(tr("Resolve each conflict", "逐项解决冲突"))
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(preview.mergePlan.conflicts) { conflict in
                            conflictCard(conflict)
                        }
                    }
                }
            }

            HStack {
                Text(tr("Final local order", "最终本地顺序"))
                    .font(.headline)
                Spacer()
                Text(tr("Drag rows to resolve ordering", "拖动行来确定顺序"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
            }

            List {
                ForEach(resolvedItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(BrandColors.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.knownTitle ?? tr("Unknown Title", "未知标题"))
                                .lineLimit(1)
                            Text(item.knownArtist ?? tr("Unknown Artist", "未知艺人"))
                                .font(.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                        Spacer()
                        if item.availability != .available {
                            Text(tr("Unavailable", "不可用"))
                                .font(.caption2)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    }
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)

            HStack {
                Text(tr("Pull changes only Muses. YouTube is not modified.",
                        "拉取只会修改 Muses，不会修改 YouTube。"))
                    .font(.caption)
                    .foregroundStyle(BrandColors.textSecondary)
                Spacer()
                Button(tr("Apply Pull", "应用拉取")) {
                    var finalItems = resolvedItems
                    for index in finalItems.indices { finalItems[index].order = index }
                    let resolved = YouTubePlaylistSnapshot(
                        playlistID: preview.local.playlistID,
                        accountChannelID: preview.local.accountChannelID,
                        title: preview.local.title,
                        capturedAt: .init(), items: finalItems)
                    onApply(resolved)
                    dismiss()
                }
                .musesAction(prominent: true)
                .tint(BrandColors.accent)
                .disabled(resolvedConflictIDs.count != preview.mergePlan.conflicts.count)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private var summary: String {
        tr("\(preview.mergePlan.remoteOnlyChanges.count) remote changes, \(preview.mergePlan.localOnlyChanges.count) local changes, \(preview.mergePlan.conflicts.count) conflicts",
           "\(preview.mergePlan.remoteOnlyChanges.count) 项远端变化，\(preview.mergePlan.localOnlyChanges.count) 项本地变化，\(preview.mergePlan.conflicts.count) 个冲突", zhHant: "\(preview.mergePlan.remoteOnlyChanges.count) 項遠端變化，\(preview.mergePlan.localOnlyChanges.count) 項本地變化，\(preview.mergePlan.conflicts.count) 個衝突")
    }

    private func conflictCard(_ conflict: YouTubePlaylistConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.local?.knownTitle ?? conflict.remote?.knownTitle
                 ?? conflict.base?.knownTitle ?? tr("Unknown item", "未知条目"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(conflictLabel(conflict.kind))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            HStack(spacing: 6) {
                Button(tr("Keep Local", "保留本地")) {
                    resolve(conflict, with: conflict.local)
                }
                Button(tr("Use YouTube", "采用 YouTube")) {
                    resolve(conflict, with: conflict.remote)
                }
            }
            .musesAction()
            if resolvedConflictIDs.contains(conflict.id) {
                Label(tr("Resolved", "已解决"), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(BrandColors.accent)
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(BrandColors.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func resolve(_ conflict: YouTubePlaylistConflict,
                         with selected: YouTubePlaylistItemSnapshot?) {
        resolvedItems.removeAll { $0.occurrenceKey == conflict.id }
        if let selected { resolvedItems.append(selected) }
        resolvedItems.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.occurrenceKey < $1.occurrenceKey
        }
        resolvedConflictIDs.insert(conflict.id)
    }

    private func move(from source: IndexSet, to destination: Int) {
        resolvedItems.move(fromOffsets: source, toOffset: destination)
        for index in resolvedItems.indices { resolvedItems[index].order = index }
    }

    private func conflictLabel(_ kind: YouTubePlaylistConflictKind) -> String {
        switch kind {
        case .divergentEdit: tr("Changed differently", "两边修改不同")
        case .removedLocallyChangedRemotely: tr("Removed locally, changed on YouTube", "本地已删除，YouTube 有修改")
        case .removedRemotelyChangedLocally: tr("Removed on YouTube, changed locally", "YouTube 已删除，本地有修改")
        case .divergentMove: tr("Moved to different positions", "两边移动到不同位置")
        }
    }
}

struct PlaylistPushPreviewSheet: View {
    let preview: YouTubePushPreview
    let onPush: () async throws -> Void
    let onCancel: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pushing = false
    @State private var confirmedTarget = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Push Preview", "推送预览"))
                .font(.title2.weight(.semibold))
            Text(tr("YouTube writes are not atomic. Muses records every completed step so a partial failure can resume safely.",
                    "YouTube 写入不是原子操作。Muses 会记录每个已完成步骤，以便部分失败后安全续传。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(preview.playlistTitle)
                    .font(.headline)
                Text("Playlist: \(preview.playlistID)")
                Text("Account: \(preview.accountChannelID)")
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)

            if preview.operations.isEmpty {
                Label(tr("YouTube already matches this local playlist", "YouTube 已与本地歌单一致"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BrandColors.textPrimary)
            } else {
                List(Array(preview.operations.enumerated()), id: \.offset) { index, operation in
                    HStack(spacing: 10) {
                        Image(systemName: operationIcon(operation.kind))
                            .frame(width: 20)
                        Text("\(index + 1). \(operationDescription(operation))")
                            .lineLimit(1)
                    }
                }
                .listStyle(.inset)

                Toggle(isOn: $confirmedTarget) {
                    Text(tr(
                        "I reviewed this exact account, playlist, and operation list, and allow Muses to write this owned playlist",
                        "我已核对这个确切账号、歌单和操作列表，并允许 Muses 写入这个归我所有的歌单",
                        zhHant: "我已核對這個確切帳號、歌單和操作列表，並允許 Muses 寫入這個歸我所有的歌單"))
                }
                .toggleStyle(.checkbox)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) {
                    cancel()
                }
                if preview.operations.isEmpty {
                    Button(tr("Done", "完成")) {
                        cancel()
                    }
                    .musesAction(prominent: true)
                    .tint(BrandColors.accent)
                } else {
                    Button(tr("Push to YouTube", "推送到 YouTube")) {
                        Task { await push() }
                    }
                    .musesAction(prominent: true)
                    .tint(BrandColors.accent)
                    .disabled(pushing || !confirmedTarget)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private func push() async {
        pushing = true
        defer { pushing = false }
        do {
            try await onPush()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        do {
            try onCancel()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func operationIcon(_ kind: YouTubeSyncOperationKind) -> String {
        switch kind {
        case .insert: "plus.circle"
        case .remove: "minus.circle"
        case .move: "arrow.up.arrow.down"
        }
    }

    private func operationDescription(_ operation: YouTubePushOperation) -> String {
        switch operation.kind {
        case .insert:
            tr("Add video at position \((operation.toPosition ?? 0) + 1)",
               "在第 \((operation.toPosition ?? 0) + 1) 位添加视频", zhHant: "在第 \((operation.toPosition ?? 0) + 1) 位添加影片")
        case .remove:
            tr("Remove playlist occurrence", "删除一个歌单条目")
        case .move:
            tr("Move to position \((operation.toPosition ?? 0) + 1)",
               "移动到第 \((operation.toPosition ?? 0) + 1) 位", zhHant: "移動到第 \((operation.toPosition ?? 0) + 1) 位")
        }
    }
}

struct NewYouTubePlaylistSheet: View {
    let onReview: (String, String?, YouTubePlaylistPrivacy) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var privacy: YouTubePlaylistPrivacy = .private
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("New YouTube Playlist", "新建 YouTube 歌单"))
                .font(.title2.weight(.semibold))
            Text(tr(
                "Nothing is created until the next exact-target confirmation.",
                "完成下一步精确目标确认前，不会创建任何远端资源。"))
                .font(.caption)
                .foregroundStyle(BrandColors.textSecondary)
            TextField(tr("Playlist title", "歌单标题"), text: $title)
                .textFieldStyle(.roundedBorder)
            TextField(tr("Description (optional)", "说明（可选）"), text: $description,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
            Picker(tr("Visibility", "可见性"), selection: $privacy) {
                Text(tr("Private", "私享")).tag(YouTubePlaylistPrivacy.private)
                Text(tr("Unlisted", "不公开")).tag(YouTubePlaylistPrivacy.unlisted)
                Text(tr("Public", "公开")).tag(YouTubePlaylistPrivacy.public)
            }
            .pickerStyle(.segmented)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                Button(tr("Review", "核对")) { review() }
                    .musesAction(prominent: true)
                    .tint(BrandColors.accent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private func review() {
        do {
            try onReview(title, description, privacy)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct YouTubePlaylistCreatePreviewSheet: View {
    let preview: YouTubePlaylistCreatePreview
    let onCreate: () async throws -> Void
    let onCancel: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        resourcePreviewShell(
            title: tr("Create Playlist on YouTube", "在 YouTube 上创建歌单"),
            warning: tr(
                "A failed response with no playlist ID will stop for manual review and will never be retried by title.",
                "若响应失败且未取得歌单 ID，操作会停止并等待人工检查，绝不会按标题盲目重试。"),
            rows: [
                (tr("Account", "账号"), preview.accountChannelID),
                (tr("Title", "标题"), preview.title),
                (tr("Visibility", "可见性"), privacyLabel(preview.privacy)),
            ],
            confirmation: tr(
                "I reviewed this exact account, title, and visibility",
                "我已核对这个确切账号、标题和可见性"),
            actionTitle: tr("Create on YouTube", "在 YouTube 上创建"),
            destructive: false,
            action: onCreate)
    }

    @ViewBuilder
    private func resourcePreviewShell(
        title: String, warning: String, rows: [(String, String)],
        confirmation: String, actionTitle: String, destructive: Bool,
        action: @escaping () async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(warning).font(.caption).foregroundStyle(BrandColors.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.0, value: row.1)
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            Toggle(confirmation, isOn: $confirmed).toggleStyle(.checkbox)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { cancel() }
                Button(actionTitle, role: destructive ? .destructive : nil) {
                    Task { await perform(action) }
                }
                .musesAction(prominent: true)
                .tint(destructive ? .red : BrandColors.accent)
                .disabled(!confirmed || working)
            }
        }
        .padding(20)
        .frame(width: 560)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private func perform(_ action: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await action()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        do {
            try onCancel()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func privacyLabel(_ privacy: YouTubePlaylistPrivacy) -> String {
        switch privacy {
        case .private: tr("Private", "私享")
        case .unlisted: tr("Unlisted", "不公开")
        case .public: tr("Public", "公开")
        }
    }
}

struct YouTubePlaylistDeletePreviewSheet: View {
    let preview: YouTubePlaylistDeletePreview
    let onDelete: () async throws -> Void
    let onCancel: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Delete Playlist from YouTube", "从 YouTube 删除歌单"))
                .font(.title2.weight(.semibold))
            Text(tr(
                "This permanently deletes the YouTube playlist. Muses keeps a pinned local recovery snapshot, but it cannot restore the same remote resource ID.",
                "这会永久删除 YouTube 歌单。Muses 会保留固定的本地恢复快照，但无法恢复相同的远端资源 ID。"))
                .font(.caption)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(tr("Account", "账号"), value: preview.accountChannelID)
                LabeledContent(tr("Playlist", "歌单"), value: preview.playlistTitle)
                LabeledContent("ID", value: preview.playlistID)
                LabeledContent(tr("Items", "条目"), value: String(preview.itemCount))
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            Toggle(isOn: $confirmed) {
                Text(tr(
                    "I reviewed this exact account and playlist and understand deletion is irreversible",
                    "我已核对这个确切账号与歌单，并了解删除不可撤销"))
            }
            .toggleStyle(.checkbox)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { cancel() }
                Button(tr("Delete from YouTube", "从 YouTube 删除"), role: .destructive) {
                    Task { await performDelete() }
                }
                .musesAction(prominent: true)
                .tint(.red)
                .disabled(!confirmed || working)
            }
        }
        .padding(20)
        .frame(width: 580)
        .musesFloatingChrome(cornerRadius: 18)
    }

    private func performDelete() async {
        working = true
        defer { working = false }
        do {
            try await onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        do {
            try onCancel()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
