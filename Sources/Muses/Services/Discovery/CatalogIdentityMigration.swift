import Foundation
import SwiftData

enum CatalogMigrationError: LocalizedError {
    case persistentStoreRequired, pendingEdits, stalePreview, noCandidates, auditFailed, conflict, recoveryRequired

    var errorDescription: String? {
        switch self {
        case .persistentStoreRequired: tr("Identity migration requires an on-disk library.", "身份迁移需要磁盘资料库。", zhHant: "身分移轉需要磁碟資料庫。")
        case .pendingEdits: tr("Save your current edits before migrating.", "请先保存当前编辑。", zhHant: "請先儲存目前編輯。")
        case .stalePreview: tr("The library changed. Refresh and review the preview again.", "资料库已变化，请刷新并重新核对预览。", zhHant: "資料庫已變更，請重新整理並再次核對預覽。")
        case .noCandidates: tr("There are no unambiguous release identities to apply.", "没有可应用的无歧义发行身份。", zhHant: "沒有可套用的無歧義發行身分。")
        case .auditFailed: tr("Library verification failed. Keep the recovery snapshot for inspection.", "资料库核对失败，请保留恢复快照以供检查。", zhHant: "資料庫核對失敗，請保留復原快照以供檢查。")
        case .conflict: tr("An affected track was removed or its identity changed. No rollback was performed.", "相关曲目已删除或身份已变化，未执行回滚。", zhHant: "相關曲目已刪除或身分已變更，未執行回復。")
        case .recoveryRequired: tr("Automatic recovery could not be verified. Keep the snapshot and stop further migration.", "无法确认自动恢复成功。请保留快照并停止后续迁移。", zhHant: "無法確認自動復原成功。請保留快照並停止後續移轉。")
        }
    }
}

struct CatalogMigrationReceipt: Codable, Equatable {
    enum State: String, Codable { case prepared, applied, rollingBack, rolledBack }
    struct Change: Codable, Equatable {
        let trackID: UUID
        let before: String?
        let after: String
    }
    let version: Int
    let createdAt: Date
    let store: URL
    let snapshot: URL
    let changes: [Change]
    let audit: CatalogMigrationAudit
    var state: State
    var fileURL: URL { snapshot.deletingLastPathComponent().appending(path: "identity-migration.json") }
}

/// Explicit local migration only. Startup never invokes apply or rollback.
@MainActor
enum CatalogIdentityMigration {
    static func storeURL(_ container: ModelContainer) throws -> URL {
        guard container.configurations.count == 1, let config = container.configurations.first,
              !config.isStoredInMemoryOnly else { throw CatalogMigrationError.persistentStoreRequired }
        guard !container.mainContext.hasChanges else { throw CatalogMigrationError.pendingEdits }
        return config.url.standardizedFileURL
    }

    static func latestReceipt(in container: ModelContainer) throws -> CatalogMigrationReceipt? {
        let store = try storeURL(container)
        let directory = store.deletingLastPathComponent()
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var receipts: [CatalogMigrationReceipt] = []
        for child in children where child.lastPathComponent.hasPrefix("catalog-identity-recovery-") {
            let file = child.appending(path: "identity-migration.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let receipt = try JSONDecoder().decode(CatalogMigrationReceipt.self, from: Data(contentsOf: file))
            guard receipt.version == 1, receipt.store.standardizedFileURL == store else { continue }
            guard receipt.fileURL.standardizedFileURL == file.standardizedFileURL else { throw CatalogMigrationError.auditFailed }
            receipts.append(receipt)
        }
        return receipts.max { $0.createdAt < $1.createdAt }
    }

    static func apply(_ preview: CatalogIdentityPreview, to container: ModelContainer,
                      afterSave: (() throws -> Void)? = nil) throws -> CatalogMigrationReceipt {
        let store = try storeURL(container)
        guard try CatalogIdentityPreview.read(from: container) == preview else { throw CatalogMigrationError.stalePreview }
        let changes = preview.rows.compactMap { row -> CatalogMigrationReceipt.Change? in
            guard case .proposed(let identity) = row.resolution else { return nil }
            return .init(trackID: row.id, before: row.currentReleaseID, after: identity)
        }
        guard !changes.isEmpty else { throw CatalogMigrationError.noCandidates }
        if let previous = try latestReceipt(in: container), [.prepared, .rollingBack].contains(previous.state) {
            throw CatalogMigrationError.recoveryRequired
        }
        let snapshot = try StoreUpgradeSnapshot.identityMigrationSnapshot(at: store)
        let audit = try CatalogMigrationAudit.read(snapshot)
        guard try CatalogMigrationAudit.read(store) == audit,
              try CatalogIdentityPreview.read(from: container) == preview else { throw CatalogMigrationError.stalePreview }
        var receipt = CatalogMigrationReceipt(version: 1, createdAt: Date(), store: store,
                                              snapshot: snapshot, changes: changes, audit: audit, state: .prepared)
        try persist(receipt)
        do {
            try write(changes, undo: false, in: container)
            try afterSave?()
            try verify(preview: preview, changes: changes, undo: false, audit: audit, store: store, container: container)
            receipt.state = .applied
            try persist(receipt)
            return receipt
        } catch {
            let failure = error
            do {
                try recover(changes, undo: true, in: container)
                receipt.state = .rolledBack
                try persist(receipt)
            } catch { throw CatalogMigrationError.recoveryRequired }
            throw failure
        }
    }

    static func rollback(_ receipt: CatalogMigrationReceipt, in container: ModelContainer,
                         afterSave: (() throws -> Void)? = nil) throws -> CatalogMigrationReceipt {
        let store = try storeURL(container)
        guard receipt.store.standardizedFileURL == store,
              receipt.version == 1, receipt.state != .rolledBack,
              try latestReceipt(in: container) == receipt,
              try CatalogMigrationAudit.read(receipt.snapshot) == receipt.audit else { throw CatalogMigrationError.conflict }
        let preview = try CatalogIdentityPreview.read(from: container)
        // A prepared receipt can survive a crash before commit. Never replay a write on launch.
        if [.prepared, .rollingBack].contains(receipt.state) && matches(receipt.changes, undo: true, preview: preview) {
            var result = receipt
            result.state = .rolledBack
            try persist(result)
            return result
        }
        guard matches(receipt.changes, undo: false, preview: preview) else { throw CatalogMigrationError.conflict }
        let beforeRollback = try StoreUpgradeSnapshot.identityMigrationSnapshot(at: store)
        let audit = try CatalogMigrationAudit.read(beforeRollback)
        var pending = receipt
        pending.state = .rollingBack
        try persist(pending)
        do {
            try write(receipt.changes, undo: true, in: container)
            try afterSave?()
            try verify(preview: preview, changes: receipt.changes, undo: true, audit: audit, store: store, container: container)
            var result = receipt
            result.state = .rolledBack
            try persist(result)
            return result
        } catch {
            let failure = error
            do {
                try recover(receipt.changes, undo: false, in: container)
                pending.state = .applied
                try persist(pending)
            }
            catch { throw CatalogMigrationError.recoveryRequired }
            throw failure
        }
    }

    private static func persist(_ receipt: CatalogMigrationReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: receipt.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.fileURL.path)
    }

    private static func matches(_ changes: [CatalogMigrationReceipt.Change], undo: Bool, preview: CatalogIdentityPreview) -> Bool {
        let rows = Dictionary(uniqueKeysWithValues: preview.rows.map { ($0.id, $0) })
        return changes.allSatisfy { change in
            guard let row = rows[change.trackID] else { return false }
            return row.currentReleaseID == (undo ? change.before : change.after)
        }
    }

    private static func recover(_ changes: [CatalogMigrationReceipt.Change], undo: Bool, in container: ModelContainer) throws {
        let current = try CatalogIdentityPreview.read(from: container)
        if matches(changes, undo: undo, preview: current) { return }
        guard matches(changes, undo: !undo, preview: current) else { throw CatalogMigrationError.conflict }
        try write(changes, undo: undo, in: container)
        guard matches(changes, undo: undo, preview: try CatalogIdentityPreview.read(from: container)) else {
            throw CatalogMigrationError.recoveryRequired
        }
    }

    private static func write(_ changes: [CatalogMigrationReceipt.Change], undo: Bool, in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for change in changes {
            guard let track = byID[change.trackID], track.releaseCatalogID == (undo ? change.after : change.before) else {
                throw CatalogMigrationError.conflict
            }
        }
        for change in changes { byID[change.trackID]?.releaseCatalogID = undo ? change.before : change.after }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private static func verify(preview: CatalogIdentityPreview, changes: [CatalogMigrationReceipt.Change], undo: Bool,
                               audit: CatalogMigrationAudit, store: URL, container: ModelContainer) throws {
        guard try CatalogMigrationAudit.read(store) == audit else { throw CatalogMigrationError.auditFailed }
        let after = try CatalogIdentityPreview.read(from: container)
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.trackID, $0) })
        guard after.rows.count == preview.rows.count else { throw CatalogMigrationError.auditFailed }
        for (before, current) in zip(preview.rows, after.rows) {
            let expected: String?
            if let change = byID[before.id] { expected = undo ? change.before : change.after }
            else { expected = before.currentReleaseID }
            guard current.id == before.id, current.title == before.title, current.evidence == before.evidence,
                  current.currentReleaseID == expected else { throw CatalogMigrationError.auditFailed }
        }
    }
}
