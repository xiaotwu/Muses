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
    struct Membership: Codable, Equatable {
        let evidenceKey: String
        let releaseID: String
        let order: Int?
        let evidenceKind: CatalogReleaseEvidenceKind
        let sourceImportID: UUID?
        let sourceItemID: UUID?
    }
    struct Change: Codable, Equatable {
        let trackID: UUID
        let before: String?
        let after: String
        let memberships: [Membership]?
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
            guard [1, 2].contains(receipt.version),
                  receipt.store.standardizedFileURL == store else { continue }
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
            guard case .proposed(let identities) = row.resolution,
                  let first = identities.first else { return nil }
            let target = Set(identities)
            let existingKeys = Set(row.membershipEvidenceKeys)
            let memberships = row.evidence.filter {
                target.contains($0.releaseID)
                    && !existingKeys.contains($0.membershipKey(trackID: row.id))
            }.map {
                CatalogMigrationReceipt.Membership(
                    evidenceKey: $0.membershipKey(trackID: row.id),
                    releaseID: $0.releaseID,
                    order: $0.order,
                    evidenceKind: .youtubeImportItem,
                    sourceImportID: $0.importID,
                    sourceItemID: $0.itemID)
            }
            guard !memberships.isEmpty else { return nil }
            let primary = YouTubeCatalogIdentity.isResolvedRelease(
                row.currentReleaseID) ? row.currentReleaseID! : first
            return .init(
                trackID: row.id,
                before: row.currentReleaseID,
                after: primary,
                memberships: memberships)
        }
        guard !changes.isEmpty else { throw CatalogMigrationError.noCandidates }
        if let previous = try latestReceipt(in: container), [.prepared, .rollingBack].contains(previous.state) {
            throw CatalogMigrationError.recoveryRequired
        }
        let snapshot = try StoreUpgradeSnapshot.identityMigrationSnapshot(at: store)
        let audit = try CatalogMigrationAudit.read(snapshot)
        guard try CatalogMigrationAudit.read(store) == audit,
              try CatalogIdentityPreview.read(from: container) == preview else { throw CatalogMigrationError.stalePreview }
        var receipt = CatalogMigrationReceipt(version: 2, createdAt: Date(), store: store,
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
              [1, 2].contains(receipt.version), receipt.state != .rolledBack,
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
        if [.prepared, .rollingBack].contains(receipt.state),
           isPartiallyRolledBack(receipt.changes, preview: preview) {
            try write(receipt.changes, undo: true, in: container)
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
            guard row.currentReleaseID == (undo ? change.before : change.after) else {
                return false
            }
            let changedKeys = Set((change.memberships ?? []).map(\.evidenceKey))
            guard !changedKeys.isEmpty else { return true }
            let currentKeys = Set(row.membershipEvidenceKeys)
            return undo
                ? changedKeys.isDisjoint(with: currentKeys)
                : changedKeys.isSubset(of: currentKeys)
        }
    }

    /// Version 2 writes the compatibility primary and relationship rows in one
    /// save. This also recognizes a conservatively simulated/crash-recovered
    /// state where the primary was restored but the exact inserted edges are
    /// still present, so an explicit rollback can finish deleting only them.
    private static func isPartiallyRolledBack(
        _ changes: [CatalogMigrationReceipt.Change],
        preview: CatalogIdentityPreview
    ) -> Bool {
        let rows = Dictionary(uniqueKeysWithValues: preview.rows.map { ($0.id, $0) })
        return changes.allSatisfy { change in
            guard let row = rows[change.trackID],
                  row.currentReleaseID == change.before else { return false }
            let changedKeys = Set((change.memberships ?? []).map(\.evidenceKey))
            return !changedKeys.isEmpty
                && changedKeys.isSubset(of: Set(row.membershipEvidenceKeys))
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
        let existingMemberships = try context.fetch(
            FetchDescriptor<CatalogTrackReleaseMembership>())
        let membershipsByKey = Dictionary(uniqueKeysWithValues:
            existingMemberships.map { ($0.evidenceKey, $0) })
        for change in changes {
            guard let track = byID[change.trackID] else {
                throw CatalogMigrationError.conflict
            }
            let expectedPrimary = undo ? change.after : change.before
            let alreadyRestoredPrimary = undo
                && !(change.memberships ?? []).isEmpty
                && track.releaseCatalogID == change.before
            guard track.releaseCatalogID == expectedPrimary || alreadyRestoredPrimary else {
                throw CatalogMigrationError.conflict
            }
            for membership in change.memberships ?? [] {
                if undo {
                    guard let row = membershipsByKey[membership.evidenceKey],
                          row.trackID == change.trackID,
                          row.releaseStableID == membership.releaseID,
                          row.releaseOrder == membership.order,
                          row.evidenceKind == membership.evidenceKind,
                          row.sourceImportID == membership.sourceImportID,
                          row.sourceItemID == membership.sourceItemID else {
                        throw CatalogMigrationError.conflict
                    }
                } else if membershipsByKey[membership.evidenceKey] != nil {
                    throw CatalogMigrationError.conflict
                }
            }
        }
        for change in changes {
            guard let track = byID[change.trackID] else {
                throw CatalogMigrationError.conflict
            }
            if undo {
                for membership in change.memberships ?? [] {
                    guard let row = membershipsByKey[membership.evidenceKey] else {
                        throw CatalogMigrationError.conflict
                    }
                    context.delete(row)
                }
            } else {
                for membership in change.memberships ?? [] {
                    context.insert(CatalogTrackReleaseMembership(
                        evidenceKey: membership.evidenceKey,
                        trackID: change.trackID,
                        releaseStableID: membership.releaseID,
                        releaseOrder: membership.order,
                        evidenceKind: membership.evidenceKind,
                        sourceImportID: membership.sourceImportID,
                        sourceItemID: membership.sourceItemID))
                }
            }
            track.releaseCatalogID = undo ? change.before : change.after
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private static func verify(preview: CatalogIdentityPreview, changes: [CatalogMigrationReceipt.Change], undo: Bool,
                               audit: CatalogMigrationAudit, store: URL, container: ModelContainer) throws {
        guard try CatalogMigrationAudit.read(store) == audit else { throw CatalogMigrationError.auditFailed }
        let after = try CatalogIdentityPreview.read(from: container)
        guard after.rows.count == preview.rows.count else { throw CatalogMigrationError.auditFailed }
        for (before, current) in zip(preview.rows, after.rows) {
            guard current.id == before.id, current.title == before.title, current.evidence == before.evidence,
                  (changes.contains { $0.trackID == before.id }
                    || current.currentReleaseID == before.currentReleaseID) else {
                throw CatalogMigrationError.auditFailed
            }
        }
        guard matches(changes, undo: undo, preview: after) else {
            throw CatalogMigrationError.auditFailed
        }
    }
}
