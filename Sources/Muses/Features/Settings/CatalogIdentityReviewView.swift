import SwiftUI
import SwiftData

/// Review direct evidence before an explicitly confirmed, recoverable migration.
struct CatalogIdentityReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(YouTubeCatalogService.self) private var catalog
    @State private var preview: CatalogIdentityPreview?
    @State private var failed = false
    @State private var loading = false
    @State private var query = ""
    @State private var candidateCount = 0
    @State private var receipt: CatalogMigrationReceipt?
    @State private var migrationAvailable = false
    @State private var migrationError: String?
    @State private var migrationNotice: String?
    @State private var confirmMigration = false
    @State private var undoRequested = false

    private var visibleRows: [CatalogIdentityPreview.Row] {
        guard let preview else { return [] }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? preview.rows : preview.rows.filter {
            $0.title.localizedStandardContains(text) || $0.id.uuidString.localizedStandardContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Review source evidence before confirming changes to library identities.",
                    "确认修改资料库身份前，请核对来源证据。",
                    zhHant: "確認修改資料庫身分前，請核對來源證據。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(tr("Find a track", "查找曲目", zhHant: "尋找曲目"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await refresh() } } label: {
                    Label(tr("Refresh preview", "刷新预览", zhHant: "重新整理預覽"), systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            migrationControls
            if loading {
                ProgressView(tr("Reading library…", "正在读取资料库…", zhHant: "正在讀取資料庫…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                ContentUnavailableView {
                    Label(tr("Unable to read library", "无法读取资料库", zhHant: "無法讀取資料庫"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(tr("No changes were made. Refresh to try again.", "未做任何修改。请刷新重试。", zhHant: "未做任何修改。請重新整理再試。"))
                }
            } else if let preview {
                Text(tr("Tracks: \(preview.rows.count) · New release relationships: \(candidateCount)",
                        "\(preview.rows.count) 首曲目 · \(candidateCount) 条新发行关系",
                        zhHant: "\(preview.rows.count) 首曲目 · \(candidateCount) 條新發行關係"))
                    .font(.caption).italic().foregroundStyle(.secondary)
                if visibleRows.isEmpty {
                    ContentUnavailableView(tr("No tracks to review", "没有可核对的曲目", zhHant: "沒有可核對的曲目"), systemImage: "music.note.list")
                } else {
                    List(visibleRows) { row in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(row.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                                ForEach(row.currentReleaseIDs, id: \.self) { current in
                                    LabeledContent(
                                        tr("Current release", "现有发行", zhHant: "現有發行"),
                                        value: current)
                                }
                                if row.evidence.isEmpty {
                                    Text(tr("No direct album membership evidence. Names and upload channels are not used to infer identity.",
                                            "缺少直接专辑归属证据。不会按名称或上传频道推断身份。",
                                            zhHant: "缺少直接專輯歸屬證據。不會按名稱或上傳頻道推斷身分。"))
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(row.evidence, id: \.itemID) { evidence in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let url = YouTubeCatalogLink.releaseURL(stableID: evidence.releaseID) {
                                            Link(evidence.releaseID, destination: url)
                                        } else {
                                            Text(evidence.releaseID)
                                        }
                                        Text(tr("Playlist position: \(evidence.order + 1)", "歌单位置：\(evidence.order + 1)", zhHant: "歌單位置：\(evidence.order + 1)"))
                                        Text(evidence.itemID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .font(.callout).padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).lineLimit(2)
                                Text(row.resolution.reviewLabel).font(.caption).italic().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsPageTitle(tr("Library identity review", "资料库身份核对", zhHant: "資料庫身分核對"))
        .task { await refresh() }
        .confirmationDialog(
            undoRequested
                ? tr("Roll back the last identity migration?", "回滚上次身份迁移？", zhHant: "回復上次身分移轉？")
                : tr("Apply release relationships (\(candidateCount))?", "应用 \(candidateCount) 条发行关系？", zhHant: "套用 \(candidateCount) 條發行關係？"),
            isPresented: $confirmMigration, titleVisibility: .visible
        ) {
            Button(undoRequested ? tr("Roll Back", "回滚", zhHant: "回復") : tr("Apply", "应用", zhHant: "套用")) {
                Task { await performMigration() }
            }
            Button(tr("Cancel", "取消", zhHant: "取消"), role: .cancel) {}
        } message: {
            Text(undoRequested
                 ? tr("Only identities changed by this migration are restored. Later likes, notes and history are retained. Conflicting identities stop the operation.", "只恢复本次迁移改动的身份，保留之后的收藏、笔记和历史。身份冲突时停止操作。", zhHant: "只復原本次移轉變更的身分，保留之後的喜愛項目、筆記和歷史。身分衝突時停止操作。")
                 : tr("An independent recovery snapshot is saved first. Every direct source-backed relationship in this preview is applied, including those hidden by search. Unsupported or indirect candidates stay unresolved.", "先保存独立恢复快照，再应用本预览中全部有直接来源证据的关系，包括搜索隐藏的条目。不受支持或间接候选保持未解析。", zhHant: "先儲存獨立復原快照，再套用本預覽中全部有直接來源證據的關係，包括搜尋隱藏的項目。不受支援或間接候選保持未解析。"))
        }
    }

    private var migrationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(tr("Apply relationships (\(candidateCount))…", "应用 \(candidateCount) 个关系…", zhHant: "套用 \(candidateCount) 個關係…")) {
                    undoRequested = false
                    confirmMigration = true
                }
                .disabled(loading || !migrationAvailable || candidateCount == 0 || receipt?.state == .prepared || receipt?.state == .rollingBack)
                if let receipt {
                    if receipt.state != .rolledBack {
                        Button(tr("Roll back last migration…", "回滚上次迁移…", zhHant: "回復上次移轉…")) {
                            undoRequested = true
                            confirmMigration = true
                        }.disabled(loading || !migrationAvailable)
                    }
                    Button(tr("Show recovery snapshot", "显示恢复快照", zhHant: "顯示復原快照")) {
                        NSWorkspace.shared.activateFileViewerSelecting([receipt.snapshot])
                    }
                }
            }
            if receipt?.state == .prepared || receipt?.state == .rollingBack {
                Text(tr("The previous operation did not finish. Review its snapshot or roll it back before continuing.", "上次操作未完成，请先检查快照或回滚。", zhHant: "上次操作未完成，請先檢查快照或回復。"))
                    .foregroundStyle(.orange)
            }
            if let migrationError {
                Label(migrationError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let migrationNotice { Text(migrationNotice).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private func performMigration() async {
        guard !loading else { return }
        loading = true
        migrationError = nil
        migrationNotice = nil
        await Task.yield()
        do {
            if undoRequested, let receipt {
                self.receipt = try CatalogIdentityMigration.rollback(receipt, in: modelContext.container)
                migrationNotice = tr("Identity changes rolled back. Later user data was retained.", "身份改动已回滚，后续用户数据已保留。", zhHant: "身分變更已回復，後續使用者資料已保留。")
            } else if let preview {
                receipt = try CatalogIdentityMigration.apply(preview, to: modelContext.container)
                migrationNotice = tr("Identity changes applied and verified. Recovery snapshot saved.", "身份改动已应用并核对，恢复快照已保存。", zhHant: "身分變更已套用並核對，復原快照已儲存。")
            }
            catalog.rebuildFromTrackMetadata()
        } catch { migrationError = error.localizedDescription }
        loading = false
        await refresh()
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        failed = false
        await Task.yield()
        guard !Task.isCancelled else { loading = false; return }
        do {
            let result = try CatalogIdentityPreview.read(from: modelContext.container)
            preview = result
            candidateCount = result.rows.reduce(into: 0) { count, row in
                if case .proposed(let releases) = row.resolution {
                    count += releases.count
                }
            }
            migrationAvailable = (try? CatalogIdentityMigration.storeURL(modelContext.container)) != nil
            if migrationAvailable {
                do { receipt = try CatalogIdentityMigration.latestReceipt(in: modelContext.container) }
                catch { migrationAvailable = false; migrationError = error.localizedDescription }
            }
        }
        catch { preview = nil; failed = true }
        loading = false
    }
}

extension CatalogIdentityPreview.Resolution {
    var reviewLabel: String {
        switch self {
        case .alreadyResolved:
            tr("Existing source identity · retained", "已有来源身份 · 保留", zhHant: "已有來源身分 · 保留")
        case .proposed:
            tr("Direct release evidence · not applied", "直接发行证据 · 未应用", zhHant: "直接發行證據 · 未套用")
        case .ambiguous:
            tr("Unsupported relationship · unresolved", "不受支持的关系 · 未解析", zhHant: "不受支援的關係 · 未解析")
        case .unresolved:
            tr("Insufficient source evidence", "来源证据不足", zhHant: "來源證據不足")
        }
    }
}
