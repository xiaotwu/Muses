import Foundation
import SwiftData
import Observation

enum YouTubePlaylistSyncError: LocalizedError, Sendable, Equatable {
    case signInRequired
    case accountMismatch
    case notOwned
    case importNotFound
    case revisionNotFound
    case conflictsRequireResolution(Int)
    case writePermissionRequired
    case remoteWritesDisabled
    case remoteChangedSincePreview
    case manualConfirmationRequired(sequence: Int)
    case incompleteRemote(itemCount: Int, pageCount: Int,
                          reason: PaginationIncompleteReason)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return tr("Sign in to YouTube before checking or updating this playlist", "请先登录 YouTube，再检查或更新此歌单")
        case .accountMismatch:
            return tr("This playlist belongs to a different YouTube account", "此歌单属于另一个 YouTube 账号")
        case .notOwned:
            return tr("This playlist is read-only for the active YouTube account", "当前 YouTube 账号对此歌单只有只读权限")
        case .importNotFound:
            return tr("YouTube playlist not found", "未找到 YouTube 歌单")
        case .revisionNotFound:
            return tr("Playlist revision not found", "未找到歌单修订")
        case .conflictsRequireResolution(let count):
            return tr("Resolve \(count) playlist conflicts before continuing", "继续前请先解决 \(count) 个歌单冲突")
        case .writePermissionRequired:
            return tr(
                "Allow YouTube playlist management before Push",
                "推送前请允许 YouTube 歌单管理权限")
        case .remoteWritesDisabled:
            return tr(
                "Remote playlist writes are disabled until sandbox rehearsal is approved",
                "沙盒演练获批前，远端歌单写入保持关闭")
        case .remoteChangedSincePreview:
            return tr(
                "The remote playlist changed after preview; review a new Push plan",
                "预览后远端歌单已变化；请重新评审新的推送计划")
        case .manualConfirmationRequired(let sequence):
            return tr(
                "Push operation \(sequence + 1) cannot be reconciled uniquely and needs confirmation",
                "第 \(sequence + 1) 个推送操作无法唯一对账，需要人工确认")
        case .incompleteRemote(let itemCount, let pageCount, let reason):
            let why = reason.detail?.isEmpty == false
                ? reason.detail!
                : reason.kind.rawValue
            return tr(
                "Remote playlist is incomplete: read \(itemCount) items across \(pageCount) pages (\(why)). Continue checking before Pull or Push.",
                "远端歌单尚未读取完整：已读取 \(pageCount) 页、\(itemCount) 条（\(why)）。请继续检查，完成前不能拉取或推送。"
            )
        case .invalidSnapshot(let message):
            return tr("Invalid playlist snapshot: \(message)", "歌单快照无效：\(message)")
        }
    }
}

enum YouTubePushExecutionPolicy: Sendable, Equatable {
    case disabled
    case enabledForTesting

    var allowsRemoteWrites: Bool { self == .enabledForTesting }
}

enum YouTubePushFaultPoint: Sendable, Equatable {
    case afterBatchStarted
    case afterOperationStarted(Int)
    case afterOperationRemoteObserved(Int)
    case afterOperationLocallyCommitted(Int)
    case afterBatchRemoteObserved
    case afterBatchLocallyCommitted
}

struct YouTubePullPreview: Sendable, Equatable {
    let importID: UUID
    let baseRevisionID: UUID
    let localRevisionID: UUID
    let remoteRevisionID: UUID
    let base: YouTubePlaylistSnapshot
    let local: YouTubePlaylistSnapshot
    let remote: YouTubePlaylistSnapshot
    let automaticResult: YouTubePlaylistSnapshot?
    let mergePlan: YouTubePlaylistMergePlan
}

extension YouTubePullPreview: Identifiable {
    var id: UUID { remoteRevisionID }
}

struct YouTubePushPreview: Sendable, Equatable {
    let importID: UUID
    let batchID: UUID
    let baseRevisionID: UUID
    let localRevisionID: UUID
    let remoteRevisionID: UUID
    let operations: [YouTubePushOperation]
    let mergePlan: YouTubePlaylistMergePlan
}

extension YouTubePushPreview: Identifiable {
    var id: UUID { batchID }
}

@MainActor
@Observable
final class YouTubePlaylistSyncService {
    static let recentlyDeletedRetention: TimeInterval = 30 * 24 * 60 * 60

    private let modelContainer: ModelContainer
    private weak var account: YouTubeAccountService?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pushExecutionPolicy: YouTubePushExecutionPolicy
    private let pushFaultInjector: (@MainActor (YouTubePushFaultPoint) throws -> Void)?
    private let log = AppLog.for("YouTubePlaylistSyncService")

    private(set) var activeImportID: UUID?
    private(set) var lastError: String?

    init(modelContainer: ModelContainer, account: YouTubeAccountService,
         pushExecutionPolicy: YouTubePushExecutionPolicy = .disabled,
         pushFaultInjector: (@MainActor (YouTubePushFaultPoint) throws -> Void)? = nil) {
        self.modelContainer = modelContainer
        self.account = account
        self.pushExecutionPolicy = pushExecutionPolicy
        self.pushFaultInjector = pushFaultInjector
    }

    // MARK: - Remote Shadow / Pull

    func checkRemote(importID: UUID) async throws -> YouTubePullPreview {
        activeImportID = importID
        defer { activeImportID = nil }
        do {
            guard let account, let client = account.dataAPIClient() else {
                throw YouTubePlaylistSyncError.signInRequired
            }
            let initialContext = ModelContext(modelContainer)
            guard let imported = try fetchImport(importID, context: initialContext) else {
                throw YouTubePlaylistSyncError.importNotFound
            }
            try verifyAccount(imported, account: account)
            let playlistID = imported.playlistId
            let title = imported.title
            let remoteResult = try await readRemotePlaylist(
                importID: importID, playlistID: playlistID, title: title,
                accountChannelID: account.activeChannelID, client: client)
            let rawRemote = Self.remoteSnapshot(
                playlistID: playlistID,
                accountChannelID: account.activeChannelID,
                title: title,
                values: remoteResult.items,
                pagination: .init(completeness: remoteResult.completeness,
                                  pageCount: remoteResult.pageCount,
                                  nextPageToken: remoteResult.nextPageToken,
                                  itemCount: remoteResult.items.count)
            )
            guard rawRemote.isCompleteRemote else {
                throw YouTubePlaylistSyncError.invalidSnapshot(
                    "Remote Shadow is not complete")
            }
            let reconciliation = try reconcileRemoteIdentities(
                importID: importID, remote: rawRemote)
            var remote = rawRemote
            remote.items = reconciliation.remote

            let context = ModelContext(modelContainer)
            guard let currentImport = try fetchImport(importID, context: context) else {
                throw YouTubePlaylistSyncError.importNotFound
            }
            try verifyAccount(currentImport, account: account)
            var local = Self.localSnapshot(currentImport)
            local.items = reconciliation.local
            currentImport.remoteWritable = account.ownsPlaylist(playlistID)
            if currentImport.accountChannelID == nil, currentImport.remoteWritable == true {
                currentImport.accountChannelID = account.activeChannelID
                local.accountChannelID = account.activeChannelID
            }

            let base: YouTubePlaylistSnapshot
            let baseRevisionID: UUID
            var trustedStoredBase: (YouTubePlaylistSnapshot, UUID)?
            if let baseID = currentImport.baseRevisionID,
               let stored = try fetchRevision(baseID, context: context) {
                let candidate = try stored.decodeSnapshot()
                if candidate.isCompleteRemote {
                    trustedStoredBase = (candidate, stored.id)
                }
            }
            if let trustedStoredBase {
                base = trustedStoredBase.0
                baseRevisionID = trustedStoredBase.1
            } else {
                // With no accepted common ancestor, the first complete Remote
                // Shadow is the only honest baseline. Local-only rows must stay
                // visible as pending Push changes.
                base = remote
                let baseRevision = try insertRevision(
                    importID: importID, accountChannelID: currentImport.accountChannelID,
                    kind: .base, snapshot: base, context: context)
                currentImport.baseRevisionID = baseRevision.id
                baseRevisionID = baseRevision.id
            }

            let localRevision = try insertRevision(
                importID: importID, accountChannelID: currentImport.accountChannelID,
                kind: .local, snapshot: local, context: context)
            let remoteRevision = try insertRevision(
                importID: importID, accountChannelID: account.activeChannelID,
                kind: .remoteShadow, snapshot: remote, context: context)
            currentImport.remoteShadowRevisionID = remoteRevision.id
            currentImport.remoteCheckedAt = .init()
            try deleteRemotePartials(importID: importID,
                                     accountChannelID: account.activeChannelID,
                                     context: context)
            try context.save()
            try pruneRevisions(importID: importID, context: context)

            let plan = YouTubePlaylistThreeWayMerge.plan(base: base, local: local, remote: remote)
            let automatic = plan.requiresResolution ? nil
                : Self.automaticallyMerged(base: base, local: local, remote: remote)
            lastError = nil
            return .init(importID: importID, baseRevisionID: baseRevisionID,
                         localRevisionID: localRevision.id,
                         remoteRevisionID: remoteRevision.id,
                         base: base, local: local, remote: remote,
                         automaticResult: automatic, mergePlan: plan)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Applies only Local and Base. It never performs a YouTube write.
    /// Local becomes the resolved merge; Base advances only to Remote Shadow.
    func applyPull(_ preview: YouTubePullPreview,
                   resolvedSnapshot: YouTubePlaylistSnapshot? = nil) throws {
        let result: YouTubePlaylistSnapshot
        if let resolvedSnapshot {
            result = resolvedSnapshot
        } else if let automatic = preview.automaticResult {
            result = automatic
        } else {
            throw YouTubePlaylistSyncError.conflictsRequireResolution(
                preview.mergePlan.conflicts.count)
        }
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(preview.importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        guard imported.remoteShadowRevisionID == preview.remoteRevisionID else {
            throw YouTubePlaylistSyncError.invalidSnapshot("Remote Shadow changed; preview again")
        }
        guard imported.baseRevisionID == preview.baseRevisionID else {
            throw YouTubePlaylistSyncError.invalidSnapshot("Base changed; preview again")
        }
        guard let localRevision = try fetchRevision(preview.localRevisionID, context: context),
              localRevision.kind == .local else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        let currentLocal = Self.localSnapshot(imported)
        guard localRevision.fingerprint == currentLocal.fingerprint else {
            throw YouTubePlaylistSyncError.invalidSnapshot("Local changed; preview again")
        }
        guard let remoteRevision = try fetchRevision(preview.remoteRevisionID, context: context),
              remoteRevision.kind == .remoteShadow else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        let acceptedRemote = try remoteRevision.decodeSnapshot()
        guard acceptedRemote.isCompleteRemote else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Pull requires a complete Remote Shadow")
        }
        _ = try insertRevision(importID: imported.id,
                               accountChannelID: imported.accountChannelID,
                               kind: .beforePull,
                               snapshot: Self.localSnapshot(imported), context: context)
        try apply(result, to: imported, context: context)
        let baseRevision = try insertRevision(
            importID: imported.id, accountChannelID: imported.accountChannelID,
            kind: .base, snapshot: acceptedRemote, context: context)
        imported.baseRevisionID = baseRevision.id
        imported.lastSyncedAt = .init()
        try context.save()
        try pruneRevisions(importID: imported.id, context: context)
    }

    // MARK: - Push journal

    /// Creates a durable preview journal. No YouTube mutation occurs here.
    func preparePush(importID: UUID) async throws -> YouTubePushPreview {
        guard let account else { throw YouTubePlaylistSyncError.signInRequired }
        let pull = try await checkRemote(importID: importID)
        guard !pull.mergePlan.requiresResolution else {
            throw YouTubePlaylistSyncError.conflictsRequireResolution(
                pull.mergePlan.conflicts.count)
        }
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        try verifyAccount(imported, account: account)
        guard account.ownsPlaylist(imported.playlistId) else {
            throw YouTubePlaylistSyncError.notOwned
        }
        let local = Self.localSnapshot(imported)
        let operations = try YouTubePushPlanner.operations(remote: pull.remote, desired: local)
        _ = try insertRevision(importID: imported.id,
                               accountChannelID: imported.accountChannelID,
                               kind: .beforePush, snapshot: local, context: context)
        let batchID = UUID()
        let batch = YouTubeSyncBatch(
            id: batchID, importID: imported.id,
            accountChannelID: imported.accountChannelID,
            playlistID: imported.playlistId,
            baseRevisionID: pull.baseRevisionID,
            localRevisionID: pull.localRevisionID,
            remoteRevisionID: pull.remoteRevisionID,
            expectedRemoteFingerprint: pull.remote.fingerprint,
            desiredSnapshotData: try encoder.encode(local),
            preRemoteSnapshotData: try encoder.encode(pull.remote))
        context.insert(batch)
        for (sequence, operation) in operations.enumerated() {
            context.insert(YouTubeSyncOperation(
                importID: imported.id, accountChannelID: imported.accountChannelID,
                batchID: batchID, sequence: sequence, kind: operation.kind,
                playlistItemID: operation.playlistItemID, videoID: operation.videoID,
                fromPosition: operation.fromPosition, toPosition: operation.toPosition,
                previousPlaylistItemID: operation.previousPlaylistItemID,
                nextPlaylistItemID: operation.nextPlaylistItemID))
        }
        try context.save()
        return .init(importID: importID, batchID: batchID,
                     baseRevisionID: pull.baseRevisionID,
                     localRevisionID: pull.localRevisionID,
                     remoteRevisionID: pull.remoteRevisionID,
                     operations: operations, mergePlan: pull.mergePlan)
    }

    /// Runs only unfinished operations and persists after each remote result.
    /// A failed batch can call this method again without replaying completed work.
    func resumePush(batchID: UUID) async throws {
        guard pushExecutionPolicy.allowsRemoteWrites else {
            throw YouTubePlaylistSyncError.remoteWritesDisabled
        }
        guard let account else {
            throw YouTubePlaylistSyncError.signInRequired
        }
        guard account.canManagePlaylists, let writer = account.playlistWriter() else {
            throw YouTubePlaylistSyncError.writePermissionRequired
        }
        let context = ModelContext(modelContainer)
        guard let batch = try fetchBatch(batchID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        if batch.state == .locallyCommitted { return }
        guard batch.state != .needsReview, batch.state != .discarded else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                batch.invalidatedReason ?? "Push batch is no longer executable")
        }
        let operations = try fetchOperations(batchID: batchID, context: context)
            .sorted { $0.sequence < $1.sequence }
        guard let imported = try fetchImport(batch.importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        try verifyAccount(imported, account: account)
        guard account.ownsPlaylist(imported.playlistId) else {
            throw YouTubePlaylistSyncError.notOwned
        }
        let desired = try batch.decodeDesiredSnapshot()
        guard Self.hasSameDesiredSequence(Self.localSnapshot(imported), desired) else {
            try invalidate(batch, reason: "Local changed after Push preview", context: context)
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Local changed after Push preview")
        }

        if batch.state == .planned {
            let currentRemote = try await fetchCompleteRemote(
                imported: imported, account: account)
            guard currentRemote.fingerprint == batch.expectedRemoteFingerprint else {
                try invalidate(batch, reason: "Remote changed after Push preview",
                               context: context)
                throw YouTubePlaylistSyncError.remoteChangedSincePreview
            }
            batch.state = .started
            batch.startedAt = .init()
            try context.save()
            try pushFaultInjector?(.afterBatchStarted)
        }

        for operation in operations where operation.state != .locallyCommitted {
            do {
                if operation.state == .needsConfirmation {
                    throw YouTubePlaylistSyncError.manualConfirmationRequired(
                        sequence: operation.sequence)
                }

                if operation.state == .started || operation.state == .failed {
                    let currentRemote = try await fetchCompleteRemote(
                        imported: imported, account: account)
                    switch try reconcile(
                        operation: operation, currentRemote: currentRemote,
                        batch: batch, operations: operations) {
                    case .notObserved:
                        operation.state = .planned
                        try context.save()
                    case .observed(let remoteResultID):
                        if operation.kind == .insert {
                            guard let remoteResultID, !remoteResultID.isEmpty else {
                                throw YouTubePlaylistSyncError.invalidSnapshot(
                                    "Reconciled insert has no playlistItem id")
                            }
                            operation.remoteResultID = remoteResultID
                        }
                        operation.state = .remoteObserved
                        operation.remoteObservedAt = .init()
                        operation.lastError = nil
                        try context.save()
                    case .ambiguous:
                        operation.state = .needsConfirmation
                        operation.lastError = YouTubePlaylistSyncError
                            .manualConfirmationRequired(sequence: operation.sequence)
                            .localizedDescription
                        try context.save()
                        throw YouTubePlaylistSyncError.manualConfirmationRequired(
                            sequence: operation.sequence)
                    }
                }

                if operation.state == .planned {
                    operation.state = .started
                    operation.startedAt = .init()
                    operation.attempts += 1
                    operation.lastError = nil
                    try context.save()
                    try pushFaultInjector?(.afterOperationStarted(operation.sequence))

                    let remoteResult = try await execute(
                        operation: operation, imported: imported, writer: writer)
                    if operation.kind == .insert {
                        guard let remoteResult, !remoteResult.isEmpty else {
                            throw YouTubePlaylistSyncError.invalidSnapshot(
                                "Insert returned no playlistItem id")
                        }
                        operation.remoteResultID = remoteResult
                    }
                    operation.state = .remoteObserved
                    operation.remoteObservedAt = .init()
                    try context.save()
                    try pushFaultInjector?(
                        .afterOperationRemoteObserved(operation.sequence))
                }

                if operation.state == .remoteObserved {
                    if operation.kind == .insert {
                        guard let remoteResult = operation.remoteResultID,
                              !remoteResult.isEmpty else {
                            throw YouTubePlaylistSyncError.invalidSnapshot(
                                "Observed insert has no playlistItem id")
                        }
                        try adoptInsertedPlaylistItemID(
                            remoteResult, operation: operation, imported: imported)
                    }
                    operation.state = .locallyCommitted
                    operation.completedAt = .init()
                    operation.lastError = nil
                    try context.save()
                    try pushFaultInjector?(
                        .afterOperationLocallyCommitted(operation.sequence))
                }
            } catch {
                operation.lastError = error.localizedDescription
                do { try context.save() } catch {
                    log.error("failed to persist push error state: \(error)")
                }
                log.error("push batch \(batchID) failed at \(operation.sequence): \(error)")
                throw error
            }
        }

        let rawVerifiedRemote = try await fetchCompleteRemote(
            imported: imported, account: account)
        let reconciliation = try reconcileRemoteIdentities(
            importID: imported.id, remote: rawVerifiedRemote)
        var verifiedRemote = rawVerifiedRemote
        verifiedRemote.items = reconciliation.remote
        var verifiedLocal = Self.localSnapshot(imported)
        verifiedLocal.items = reconciliation.local
        guard verifiedLocal.isStructurallyEquivalent(to: verifiedRemote) else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Verified remote state does not match Local after Push")
        }
        batch.state = .remoteObserved
        batch.remoteObservedAt = .init()
        try context.save()
        try pushFaultInjector?(.afterBatchRemoteObserved)

        let verificationContext = ModelContext(modelContainer)
        guard let verifiedImport = try fetchImport(imported.id, context: verificationContext) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let remoteRevision = try insertRevision(
            importID: verifiedImport.id, accountChannelID: verifiedImport.accountChannelID,
            kind: .remoteShadow, snapshot: verifiedRemote, context: verificationContext)
        let baseRevision = try insertRevision(
            importID: verifiedImport.id, accountChannelID: verifiedImport.accountChannelID,
            kind: .base, snapshot: verifiedRemote, context: verificationContext)
        verifiedImport.remoteShadowRevisionID = remoteRevision.id
        verifiedImport.baseRevisionID = baseRevision.id
        verifiedImport.remoteCheckedAt = .init()
        verifiedImport.lastSyncedAt = .init()
        try deleteRemotePartials(importID: verifiedImport.id,
                                 accountChannelID: verifiedImport.accountChannelID,
                                 context: verificationContext)
        try verificationContext.save()
        try pruneRevisions(importID: verifiedImport.id, context: verificationContext)

        let completionContext = ModelContext(modelContainer)
        guard let completedBatch = try fetchBatch(batchID, context: completionContext) else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Push batch disappeared before local commit")
        }
        completedBatch.state = .locallyCommitted
        completedBatch.completedAt = .init()
        completedBatch.invalidatedReason = nil
        try completionContext.save()
        try pushFaultInjector?(.afterBatchLocallyCommitted)
    }

    func discardPush(batchID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let batch = try fetchBatch(batchID, context: context) else { return }
        guard batch.state == .planned || batch.state == .needsReview else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "A started Push batch cannot be discarded")
        }
        for operation in try fetchOperations(batchID: batchID, context: context) {
            context.delete(operation)
        }
        batch.state = .discarded
        batch.completedAt = .init()
        try context.save()
    }

    // MARK: - Recovery

    func saveLocalRevision(importID: UUID,
                           kind: YouTubePlaylistRevisionKind = .local,
                           pinned: Bool = false) throws -> UUID {
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let revision = try insertRevision(
            importID: importID, accountChannelID: imported.accountChannelID,
            kind: kind, snapshot: Self.localSnapshot(imported),
            pinned: pinned, context: context)
        try context.save()
        try pruneRevisions(importID: importID, context: context)
        return revision.id
    }

    func moveToRecentlyDeleted(importID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        _ = try insertRevision(importID: importID,
                               accountChannelID: imported.accountChannelID,
                               kind: .beforeDelete,
                               snapshot: Self.localSnapshot(imported), context: context)
        imported.deletedAt = .init()
        try context.save()
        try pruneRevisions(importID: importID, context: context)
    }

    static func isWithinRecentlyDeletedRetention(_ imported: YouTubeImport,
                                                  now: Date = .init()) -> Bool {
        guard let deletedAt = imported.deletedAt else { return false }
        return deletedAt >= now.addingTimeInterval(-recentlyDeletedRetention)
    }

    /// Removes expired, unpinned tombstones without touching their Track rows
    /// or any remote playlist. A pinned revision keeps its hidden tombstone so
    /// the revision remains restorable after the 30-day Recently Deleted window.
    @discardableResult
    func purgeExpiredRecentlyDeleted(now: Date = .init()) throws -> Int {
        let context = ModelContext(modelContainer)
        let imports = try context.fetch(FetchDescriptor<YouTubeImport>())
        let revisions = try context.fetch(FetchDescriptor<YouTubePlaylistRevision>())
        let operations = try context.fetch(FetchDescriptor<YouTubeSyncOperation>())
        let batches = try context.fetch(FetchDescriptor<YouTubeSyncBatch>())
        let pinnedImportIDs = Set(revisions.filter(\.pinned).map(\.importID))
        var removed = 0

        for imported in imports {
            guard imported.deletedAt != nil,
                  !Self.isWithinRecentlyDeletedRetention(imported, now: now),
                  !pinnedImportIDs.contains(imported.id) else { continue }
            for revision in revisions where revision.importID == imported.id {
                context.delete(revision)
            }
            for operation in operations where operation.importID == imported.id {
                context.delete(operation)
            }
            for batch in batches where batch.importID == imported.id {
                context.delete(batch)
            }
            context.delete(imported)
            removed += 1
        }
        if removed > 0 { try context.save() }
        return removed
    }

    func setRevisionPinned(revisionID: UUID, pinned: Bool) throws {
        let context = ModelContext(modelContainer)
        guard let revision = try fetchRevision(revisionID, context: context) else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        guard revision.kind != .remotePartial else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Remote Partial cannot be pinned")
        }
        revision.pinned = pinned
        try context.save()
    }

    func compareRevisions(olderID: UUID,
                          newerID: UUID) throws -> YouTubePlaylistRevisionComparison {
        let context = ModelContext(modelContainer)
        guard let older = try fetchRevision(olderID, context: context),
              let newer = try fetchRevision(newerID, context: context) else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        guard older.importID == newer.importID else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Revisions belong to different playlists")
        }
        let olderItems = try older.decodeSnapshot().normalizedItems
        let newerItems = try newer.decodeSnapshot().normalizedItems
        let olderByKey = Dictionary(uniqueKeysWithValues: olderItems.map { ($0.occurrenceKey, $0) })
        let newerByKey = Dictionary(uniqueKeysWithValues: newerItems.map { ($0.occurrenceKey, $0) })
        let keys = Set(olderByKey.keys).union(newerByKey.keys)
        let changes = keys.compactMap { key -> YouTubePlaylistRevisionChange? in
            switch (olderByKey[key], newerByKey[key]) {
            case (nil, let item?):
                return .init(id: "inserted:\(key)", kind: .inserted, item: item,
                             fromPosition: nil, toPosition: item.order)
            case (let item?, nil):
                return .init(id: "removed:\(key)", kind: .removed, item: item,
                             fromPosition: item.order, toPosition: nil)
            case (let old?, let new?) where old.order != new.order:
                return .init(id: "moved:\(key)", kind: .moved, item: new,
                             fromPosition: old.order, toPosition: new.order)
            default:
                return nil
            }
        }.sorted { lhs, rhs in
            let lhsPosition = lhs.toPosition ?? lhs.fromPosition ?? .max
            let rhsPosition = rhs.toPosition ?? rhs.fromPosition ?? .max
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            return lhs.id < rhs.id
        }
        return .init(olderRevisionID: olderID, newerRevisionID: newerID,
                     changes: changes)
    }

    /// Restores Local only; it deliberately does not enqueue or run Push.
    func restore(revisionID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let revision = try fetchRevision(revisionID, context: context) else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        guard revision.kind != .remotePartial else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Remote Partial is internal continuation state and cannot be restored")
        }
        guard let imported = try fetchImport(revision.importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let snapshot = try revision.decodeSnapshot()
        _ = try insertRevision(importID: imported.id,
                               accountChannelID: imported.accountChannelID,
                               kind: .beforeRestore,
                               snapshot: Self.localSnapshot(imported), context: context)
        try apply(snapshot, to: imported, context: context)
        imported.deletedAt = nil
        _ = try insertRevision(importID: imported.id,
                               accountChannelID: imported.accountChannelID,
                               kind: .restored,
                               snapshot: snapshot, context: context)
        try context.save()
        try pruneRevisions(importID: imported.id, context: context)
    }

    /// Creates a detached Muses playlist from a revision. It has no sync
    /// ownership and therefore cannot enqueue or execute a YouTube Push.
    func restoreAsCopy(revisionID: UUID, name: String? = nil) throws -> UUID {
        let context = ModelContext(modelContainer)
        guard let revision = try fetchRevision(revisionID, context: context) else {
            throw YouTubePlaylistSyncError.revisionNotFound
        }
        guard revision.kind != .remotePartial else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Remote Partial is internal continuation state and cannot be restored")
        }
        let snapshot = try revision.decodeSnapshot()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmedName?.isEmpty == false
                                ? trimmedName!
                                : tr("\(snapshot.title) — Recovered Copy",
                                     "\(snapshot.title) — 恢复副本"))
        context.insert(playlist)
        var items: [PlaylistItem] = []
        for (order, value) in snapshot.normalizedItems.enumerated() {
            guard !value.videoID.isEmpty else { continue }
            let track = try reusableTrack(for: value, context: context)
            let item = PlaylistItem(order: order, playlist: playlist, track: track)
            context.insert(item)
            items.append(item)
        }
        playlist.items = items
        try context.save()
        NotificationCenter.default.post(name: .musesPlaylistsChanged, object: nil)
        return playlist.id
    }

    func revisions(importID: UUID) throws -> [YouTubePlaylistRevision] {
        let context = ModelContext(modelContainer)
        let id = importID
        let descriptor = FetchDescriptor<YouTubePlaylistRevision>(
            predicate: #Predicate { $0.importID == id },
            sortBy: [SortDescriptor(\YouTubePlaylistRevision.createdAt, order: .reverse)])
        return try context.fetch(descriptor).filter { $0.kind != .remotePartial }
    }

    func revisionSummaries(importID: UUID) throws -> [YouTubePlaylistRevisionSummary] {
        try revisions(importID: importID).map { revision in
            .init(id: revision.id, importID: revision.importID,
                  kind: revision.kind, createdAt: revision.createdAt,
                  fingerprint: revision.fingerprint, pinned: revision.pinned,
                  itemCount: try revision.decodeSnapshot().items.count)
        }
    }

    func overviewStatus(importID: UUID) throws -> YouTubePlaylistOverviewStatus {
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let target = importID
        let revisions = try context.fetch(FetchDescriptor<YouTubePlaylistRevision>(
            predicate: #Predicate { $0.importID == target }))
        let batches = try context.fetch(FetchDescriptor<YouTubeSyncBatch>(
            predicate: #Predicate { $0.importID == target }))
            .sorted { $0.createdAt > $1.createdAt }
        let operations = try context.fetch(FetchDescriptor<YouTubeSyncOperation>(
            predicate: #Predicate { $0.importID == target }))

        let base = imported.baseRevisionID.flatMap { id in
            revisions.first { $0.id == id }
        }.flatMap { try? $0.decodeSnapshot() }
        let remote = imported.remoteShadowRevisionID.flatMap { id in
            revisions.first { $0.id == id }
        }.flatMap { try? $0.decodeSnapshot() }
        let local = Self.localSnapshot(imported)

        let pendingCount: Int = {
            guard let base else { return 0 }
            return (try? YouTubePushPlanner.operations(remote: base, desired: local).count) ?? 0
        }()
        let conflictCount: Int = {
            guard let base, let remote, remote.isCompleteRemote else { return 0 }
            return YouTubePlaylistThreeWayMerge.plan(
                base: base, local: local, remote: remote).conflicts.count
        }()
        let latestBatch = batches.first { $0.state != .discarded }
        let latestBatchOperations = latestBatch.map { batch in
            operations.filter { $0.batchID == batch.id }
        } ?? []
        let operationError = latestBatchOperations
            .sorted { $0.sequence < $1.sequence }
            .compactMap(\.lastError)
            .first
        let batchError = latestBatch.flatMap { batch -> String? in
            guard batch.state == .needsReview else { return nil }
            return batch.invalidatedReason
        }
        let lastPushAt = batches
            .filter { $0.state == .locallyCommitted }
            .compactMap(\.completedAt)
            .max()
        let lastPullAt = revisions
            .filter { $0.kind == .beforePull }
            .map(\.createdAt)
            .max()

        return .init(
            lastRemoteCheckAt: imported.remoteCheckedAt,
            lastPullAt: lastPullAt,
            lastPushAt: lastPushAt,
            pendingLocalChangeCount: pendingCount,
            conflictCount: conflictCount,
            hasIncompleteRemote: revisions.contains { $0.kind == .remotePartial },
            remoteWritable: imported.remoteWritable,
            needsReview: latestBatch?.state == .needsReview
                || latestBatchOperations.contains { $0.state == .needsConfirmation },
            errorMessage: operationError ?? batchError)
    }

    // MARK: - Push execution / reconciliation

    private enum RemoteObservation {
        case notObserved
        case observed(String?)
        case ambiguous
    }

    private func execute(
        operation: YouTubeSyncOperation,
        imported: YouTubeImport,
        writer: YouTubePlaylistWriteService
    ) async throws -> String? {
        switch operation.kind {
        case .insert:
            return try await writer.addVideo(
                playlistId: imported.playlistId, videoId: operation.videoID,
                position: operation.toPosition)
        case .remove:
            guard let id = operation.playlistItemID, !id.isEmpty else {
                throw YouTubePlaylistSyncError.invalidSnapshot(
                    "Remove is missing playlistItem id")
            }
            try await writer.removeItem(playlistItemID: id)
            return nil
        case .move:
            guard let id = operation.playlistItemID, !id.isEmpty,
                  let target = operation.toPosition else {
                throw YouTubePlaylistSyncError.invalidSnapshot(
                    "Move is missing identity or position")
            }
            try await writer.moveItem(
                playlistItemID: id, playlistId: imported.playlistId,
                videoId: operation.videoID, to: target)
            return nil
        }
    }

    private func fetchCompleteRemote(
        imported: YouTubeImport,
        account: YouTubeAccountService
    ) async throws -> YouTubePlaylistSnapshot {
        guard let client = account.dataAPIClient() else {
            throw YouTubePlaylistSyncError.signInRequired
        }
        let result = try await readRemotePlaylist(
            importID: imported.id, playlistID: imported.playlistId,
            title: imported.title, accountChannelID: account.activeChannelID,
            client: client)
        let snapshot = Self.remoteSnapshot(
            playlistID: imported.playlistId,
            accountChannelID: account.activeChannelID,
            title: imported.title, values: result.items,
            pagination: .init(
                completeness: result.completeness,
                pageCount: result.pageCount,
                nextPageToken: result.nextPageToken,
                itemCount: result.items.count))
        guard snapshot.isCompleteRemote else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Push requires a complete Remote Shadow")
        }
        return snapshot
    }

    private func invalidate(_ batch: YouTubeSyncBatch, reason: String,
                            context: ModelContext) throws {
        batch.state = .needsReview
        batch.invalidatedReason = reason
        try context.save()
    }

    private static func hasSameDesiredSequence(
        _ current: YouTubePlaylistSnapshot,
        _ desired: YouTubePlaylistSnapshot
    ) -> Bool {
        guard current.playlistID == desired.playlistID else { return false }
        let lhs = current.normalizedItems
        let rhs = desired.normalizedItems
        guard lhs.count == rhs.count else { return false }
        for (currentItem, desiredItem) in zip(lhs, rhs) {
            guard currentItem.videoID == desiredItem.videoID,
                  currentItem.availability == desiredItem.availability else {
                return false
            }
            if let expectedID = desiredItem.normalizedPlaylistItemID,
               currentItem.normalizedPlaylistItemID != expectedID {
                return false
            }
        }
        return true
    }

    private func reconcile(
        operation: YouTubeSyncOperation,
        currentRemote: YouTubePlaylistSnapshot,
        batch: YouTubeSyncBatch,
        operations: [YouTubeSyncOperation]
    ) throws -> RemoteObservation {
        let expected = try expectedRemoteBefore(
            operation: operation, batch: batch, operations: operations)
        if currentRemote.fingerprint == expected.fingerprint {
            return .notObserved
        }

        let current = currentRemote.normalizedItems
        switch operation.kind {
        case .insert:
            let oldIDs = Set(expected.normalizedItems.compactMap(\.normalizedPlaylistItemID))
            let candidates = current.indices.filter { index in
                let item = current[index]
                guard item.videoID == operation.videoID,
                      let id = item.normalizedPlaylistItemID,
                      !oldIDs.contains(id) else { return false }
                return Self.matchesExpectedLocation(
                    index: index, items: current,
                    target: operation.toPosition,
                    previousID: operation.previousPlaylistItemID,
                    nextID: operation.nextPlaylistItemID)
            }
            if candidates.count == 1 {
                return .observed(current[candidates[0]].normalizedPlaylistItemID)
            }
            return .ambiguous

        case .remove:
            guard let id = operation.playlistItemID else { return .ambiguous }
            return current.contains { $0.normalizedPlaylistItemID == id }
                ? .ambiguous : .observed(nil)

        case .move:
            guard let id = operation.playlistItemID,
                  let index = current.firstIndex(where: {
                      $0.normalizedPlaylistItemID == id
                  }) else { return .ambiguous }
            return Self.matchesExpectedLocation(
                index: index, items: current,
                target: operation.toPosition,
                previousID: operation.previousPlaylistItemID,
                nextID: operation.nextPlaylistItemID)
                ? .observed(nil) : .ambiguous
        }
    }

    private static func matchesExpectedLocation(
        index: Int,
        items: [YouTubePlaylistItemSnapshot],
        target: Int?,
        previousID: String?,
        nextID: String?
    ) -> Bool {
        if let target, target != index { return false }
        if let previousID {
            guard index > 0,
                  items[index - 1].normalizedPlaylistItemID == previousID else {
                return false
            }
        }
        if let nextID {
            guard index + 1 < items.count,
                  items[index + 1].normalizedPlaylistItemID == nextID else {
                return false
            }
        }
        return true
    }

    private func expectedRemoteBefore(
        operation target: YouTubeSyncOperation,
        batch: YouTubeSyncBatch,
        operations: [YouTubeSyncOperation]
    ) throws -> YouTubePlaylistSnapshot {
        var snapshot = try batch.decodePreRemoteSnapshot()
        var items = snapshot.normalizedItems
        for operation in operations where operation.sequence < target.sequence {
            switch operation.kind {
            case .remove:
                guard let id = operation.playlistItemID,
                      let index = items.firstIndex(where: {
                          $0.normalizedPlaylistItemID == id
                      }) else {
                    throw YouTubePlaylistSyncError.invalidSnapshot(
                        "Cannot simulate a completed remove")
                }
                items.remove(at: index)
            case .move:
                guard let id = operation.playlistItemID,
                      let source = items.firstIndex(where: {
                          $0.normalizedPlaylistItemID == id
                      }), let destination = operation.toPosition else {
                    throw YouTubePlaylistSyncError.invalidSnapshot(
                        "Cannot simulate a completed move")
                }
                let item = items.remove(at: source)
                items.insert(item, at: min(destination, items.count))
            case .insert:
                guard let id = operation.remoteResultID, !id.isEmpty,
                      let destination = operation.toPosition else {
                    throw YouTubePlaylistSyncError.invalidSnapshot(
                        "Cannot simulate an insert without its remote identity")
                }
                let item = YouTubePlaylistItemSnapshot(
                    id: UUID(), playlistItemID: id,
                    videoID: operation.videoID, title: nil, artist: nil,
                    durationMs: nil, order: destination,
                    availability: .available)
                items.insert(item, at: min(destination, items.count))
            }
            for index in items.indices { items[index].order = index }
        }
        snapshot.items = items
        return snapshot
    }

    // MARK: - Complete remote pagination

    /// Reads until YouTube returns no continuation token. Every completed page
    /// is durably accumulated in a Remote Partial revision. Only the caller's
    /// later transaction may publish the result as Remote Shadow.
    private func readRemotePlaylist(
        importID: UUID,
        playlistID: String,
        title: String,
        accountChannelID: String?,
        client: YouTubeDataAPIClient
    ) async throws -> PaginatedResult<YouTubePlaylistItem> {
        let continuation = try latestRemotePartial(
            importID: importID, playlistID: playlistID,
            accountChannelID: accountChannelID)
        var values = continuation?.normalizedItems.map(Self.remoteValue) ?? []
        var pageCount = continuation?.pagination?.pageCount ?? 0
        var pageToken = continuation?.pagination?.nextPageToken

        while pageCount < client.maxPages {
            if Task.isCancelled {
                try stopIncompleteRemote(
                    importID: importID, playlistID: playlistID, title: title,
                    accountChannelID: accountChannelID, values: values,
                    pageCount: pageCount, nextPageToken: pageToken,
                    reason: .init(.cancelled))
            }

            let page: PaginationPage<YouTubePlaylistItem>
            do {
                page = try await client.playlistItemsPage(
                    playlistId: playlistID, pageToken: pageToken)
            } catch {
                try stopIncompleteRemote(
                    importID: importID, playlistID: playlistID, title: title,
                    accountChannelID: accountChannelID, values: values,
                    pageCount: pageCount, nextPageToken: pageToken,
                    reason: Self.paginationReason(for: error))
            }

            values.append(contentsOf: page.items)
            pageCount += 1
            pageToken = page.nextPageToken
            if pageToken == nil {
                return .init(items: values, completeness: .complete,
                             pageCount: pageCount, nextPageToken: nil)
            }

            let progress = PaginatedResult(
                items: values,
                completeness: .incomplete(.init(.continuation)),
                pageCount: pageCount,
                nextPageToken: pageToken)
            try persistRemotePartial(
                importID: importID, playlistID: playlistID, title: title,
                accountChannelID: accountChannelID, result: progress)
        }

        try stopIncompleteRemote(
            importID: importID, playlistID: playlistID, title: title,
            accountChannelID: accountChannelID, values: values,
            pageCount: pageCount, nextPageToken: pageToken,
            reason: .init(.safetyLimit, detail: "\(client.maxPages) pages"))
    }

    private func stopIncompleteRemote(
        importID: UUID,
        playlistID: String,
        title: String,
        accountChannelID: String?,
        values: [YouTubePlaylistItem],
        pageCount: Int,
        nextPageToken: String?,
        reason: PaginationIncompleteReason
    ) throws -> Never {
        let result = PaginatedResult(
            items: values, completeness: .incomplete(reason),
            pageCount: pageCount, nextPageToken: nextPageToken)
        try persistRemotePartial(
            importID: importID, playlistID: playlistID, title: title,
            accountChannelID: accountChannelID, result: result)
        throw YouTubePlaylistSyncError.incompleteRemote(
            itemCount: values.count, pageCount: pageCount, reason: reason)
    }

    private func persistRemotePartial(
        importID: UUID,
        playlistID: String,
        title: String,
        accountChannelID: String?,
        result: PaginatedResult<YouTubePlaylistItem>
    ) throws {
        guard !result.isComplete else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "A complete result cannot be stored as Remote Partial")
        }
        let context = ModelContext(modelContainer)
        guard try fetchImport(importID, context: context) != nil else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let snapshot = Self.remoteSnapshot(
            playlistID: playlistID, accountChannelID: accountChannelID,
            title: title, values: result.items,
            pagination: .init(completeness: result.completeness,
                              pageCount: result.pageCount,
                              nextPageToken: result.nextPageToken,
                              itemCount: result.items.count))
        let revisions = try remotePartialRevisions(
            importID: importID, accountChannelID: accountChannelID,
            context: context)
        if let partial = revisions.first {
            partial.snapshotData = try encoder.encode(snapshot)
            partial.fingerprint = snapshot.fingerprint
            partial.createdAt = .init()
            for stale in revisions.dropFirst() { context.delete(stale) }
        } else {
            _ = try insertRevision(
                importID: importID, accountChannelID: accountChannelID,
                kind: .remotePartial, snapshot: snapshot, context: context)
        }
        try context.save()
    }

    private func latestRemotePartial(
        importID: UUID,
        playlistID: String,
        accountChannelID: String?
    ) throws -> YouTubePlaylistSnapshot? {
        let context = ModelContext(modelContainer)
        for revision in try remotePartialRevisions(
            importID: importID, accountChannelID: accountChannelID,
            context: context) {
            let snapshot = try revision.decodeSnapshot()
            guard snapshot.playlistID == playlistID,
                  let pagination = snapshot.pagination,
                  !pagination.completeness.isComplete,
                  pagination.itemCount == snapshot.items.count else { continue }
            return snapshot
        }
        return nil
    }

    private func remotePartialRevisions(
        importID: UUID,
        accountChannelID: String?,
        context: ModelContext
    ) throws -> [YouTubePlaylistRevision] {
        let id = importID
        let descriptor = FetchDescriptor<YouTubePlaylistRevision>(
            predicate: #Predicate { $0.importID == id },
            sortBy: [SortDescriptor(\YouTubePlaylistRevision.createdAt, order: .reverse)])
        return try context.fetch(descriptor).filter {
            $0.kind == .remotePartial && $0.accountChannelID == accountChannelID
        }
    }

    private func deleteRemotePartials(
        importID: UUID,
        accountChannelID: String?,
        context: ModelContext
    ) throws {
        for revision in try remotePartialRevisions(
            importID: importID, accountChannelID: accountChannelID,
            context: context) {
            context.delete(revision)
        }
    }

    private nonisolated static func remoteValue(
        _ item: YouTubePlaylistItemSnapshot
    ) -> YouTubePlaylistItem {
        .init(playlistItemId: item.normalizedPlaylistItemID ?? "",
              videoId: item.videoID, title: item.knownTitle ?? "",
              channelTitle: item.knownArtist ?? "", thumbnailURL: nil,
              availability: item.availability)
    }

    private nonisolated static func paginationReason(
        for error: Error
    ) -> PaginationIncompleteReason {
        YouTubeDataAPIClient.paginationReason(for: error)
    }

    // MARK: - Snapshot helpers

    static func localSnapshot(_ imported: YouTubeImport,
                              capturedAt: Date = .init()) -> YouTubePlaylistSnapshot {
        let items = (imported.items ?? []).map {
            YouTubePlaylistItemSnapshot(
                id: $0.id, playlistItemID: $0.playlistItemID,
                videoID: $0.youTubeId,
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : $0.title,
                artist: $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : $0.artist,
                durationMs: $0.durationMs > 0 ? $0.durationMs : nil, order: $0.order,
                availability: $0.availability)
        }
        return .init(playlistID: imported.playlistId,
                     accountChannelID: imported.accountChannelID,
                     title: imported.title, capturedAt: capturedAt, items: items)
    }

    static func remoteSnapshot(playlistID: String, accountChannelID: String?,
                               title: String, values: [YouTubePlaylistItem],
                               pagination: YouTubePlaylistPaginationMetadata? = nil,
                               capturedAt: Date = .init()) -> YouTubePlaylistSnapshot {
        .init(playlistID: playlistID, accountChannelID: accountChannelID,
              title: title, capturedAt: capturedAt,
              items: values.enumerated().map { index, item in
            .init(id: UUID(),
                  playlistItemID: item.playlistItemId.isEmpty ? nil : item.playlistItemId,
                  videoID: item.videoId,
                  title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : item.title,
                  artist: item.channelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : item.channelTitle,
                  durationMs: nil, order: index,
                  availability: item.availability)
        }, pagination: pagination)
    }

    nonisolated static func automaticallyMerged(
        base: YouTubePlaylistSnapshot,
        local: YouTubePlaylistSnapshot,
        remote: YouTubePlaylistSnapshot
    ) -> YouTubePlaylistSnapshot {
        let baseMap = Dictionary(uniqueKeysWithValues: base.items.map { ($0.occurrenceKey, $0) })
        let localMap = Dictionary(uniqueKeysWithValues: local.items.map { ($0.occurrenceKey, $0) })
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.occurrenceKey, $0) })
        let keys = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys)
        var merged: [YouTubePlaylistItemSnapshot] = []
        for key in keys {
            let b = baseMap[key]
            let l = localMap[key]
            let r = remoteMap[key]
            let localChanged = !YouTubePlaylistThreeWayMerge.structurallyEqual(l, b)
            let remoteChanged = !YouTubePlaylistThreeWayMerge.structurallyEqual(r, b)
            let chosen: YouTubePlaylistItemSnapshot?
            if localChanged && !remoteChanged {
                chosen = l?.fillingUnknownMetadata(from: r, b)
            } else if remoteChanged && !localChanged {
                chosen = r?.fillingUnknownMetadata(from: l, b)
            } else if YouTubePlaylistThreeWayMerge.structurallyEqual(l, r) {
                chosen = l?.fillingUnknownMetadata(from: r, b)
                    ?? r?.fillingUnknownMetadata(from: l, b)
            } else {
                chosen = l?.fillingUnknownMetadata(from: r, b)
            }
            if let chosen { merged.append(chosen) }
        }
        merged.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.occurrenceKey < $1.occurrenceKey
        }
        for index in merged.indices { merged[index].order = index }
        return .init(playlistID: local.playlistID,
                     accountChannelID: local.accountChannelID,
                     title: local.title, capturedAt: .init(), items: merged)
    }

    // MARK: - Persistence helpers

    private func insertRevision(importID: UUID, accountChannelID: String?,
                                kind: YouTubePlaylistRevisionKind,
                                snapshot: YouTubePlaylistSnapshot,
                                pinned: Bool = false,
                                context: ModelContext) throws -> YouTubePlaylistRevision {
        let data = try encoder.encode(snapshot)
        let revision = YouTubePlaylistRevision(
            importID: importID, accountChannelID: accountChannelID,
            kind: kind, snapshotData: data, fingerprint: snapshot.fingerprint,
            pinned: pinned)
        context.insert(revision)
        return revision
    }

    private func pruneRevisions(importID: UUID, now: Date = .init(),
                                context: ModelContext) throws {
        let id = importID
        let descriptor = FetchDescriptor<YouTubePlaylistRevision>(
            predicate: #Predicate { $0.importID == id },
            sortBy: [SortDescriptor(\YouTubePlaylistRevision.createdAt, order: .reverse)])
        let all = try context.fetch(descriptor)
        let newestIDs = Set(all.prefix(50).map(\.id))
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        for revision in all where !revision.pinned
            && !newestIDs.contains(revision.id)
            && revision.createdAt < cutoff {
            context.delete(revision)
        }
        try context.save()
    }

    private func apply(_ snapshot: YouTubePlaylistSnapshot,
                       to imported: YouTubeImport,
                       context: ModelContext) throws {
        guard snapshot.playlistID == imported.playlistId else {
            throw YouTubePlaylistSyncError.invalidSnapshot("playlist id mismatch")
        }
        let existing = imported.items ?? []
        var byRemote = Dictionary(uniqueKeysWithValues: existing.compactMap { item in
            item.playlistItemID.map { ($0, item) }
        })
        var byLocal = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var result: [YouTubeImportItem] = []

        for value in snapshot.normalizedItems {
            let item: YouTubeImportItem
            if let remoteID = value.playlistItemID,
               let found = byRemote.removeValue(forKey: remoteID) {
                item = found
                byLocal.removeValue(forKey: found.id)
            } else if let found = byLocal.removeValue(forKey: value.id) {
                item = found
                if let remoteID = found.playlistItemID { byRemote.removeValue(forKey: remoteID) }
            } else {
                item = YouTubeImportItem(
                    id: value.id, youTubeId: value.videoID,
                    title: value.knownTitle ?? tr("Unknown Title", "未知标题"),
                    artist: value.knownArtist ?? tr("Unknown Artist", "未知艺人"),
                    durationMs: value.knownDurationMs ?? 0,
                    order: value.order, playlistItemID: value.playlistItemID,
                    availability: value.availability)
                context.insert(item)
            }
            item.import_ = imported
            item.playlistItemID = value.playlistItemID
            item.youTubeId = value.videoID
            if let title = value.knownTitle { item.title = title }
            if let artist = value.knownArtist { item.artist = artist }
            if let durationMs = value.knownDurationMs { item.durationMs = durationMs }
            item.order = value.order
            item.availability = value.availability
            if item.track == nil, !value.videoID.isEmpty {
                item.track = try reusableTrack(for: value, context: context)
            }
            result.append(item)
        }

        let leftovers = Set(byLocal.values.map(\.id)).union(byRemote.values.map(\.id))
        for item in existing where leftovers.contains(item.id) { context.delete(item) }
        imported.items = result
    }

    private func reusableTrack(for item: YouTubePlaylistItemSnapshot,
                               context: ModelContext) throws -> Track {
        let videoID = item.videoID
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.youTubeId == videoID })
        if let existing = try context.fetch(descriptor).first { return existing }
        let track = Track(title: item.knownTitle ?? tr("Unknown Title", "未知标题"),
                          artist: item.knownArtist ?? tr("Unknown Artist", "未知艺人"),
                          durationMs: item.knownDurationMs ?? 0, youTubeId: item.videoID,
                          artworkUrl: YouTubeThumbnail.urlString(videoId: item.videoID),
                          availability: item.availability == .available ? .available : .unavailable)
        context.insert(track)
        return track
    }

    private func verifyAccount(_ imported: YouTubeImport,
                               account: YouTubeAccountService) throws {
        if let owner = imported.accountChannelID {
            guard let active = account.activeChannelID else {
                throw YouTubePlaylistSyncError.signInRequired
            }
            guard owner == active else {
                throw YouTubePlaylistSyncError.accountMismatch
            }
        }
    }

    private func adoptInsertedPlaylistItemID(
        _ playlistItemID: String,
        operation: YouTubeSyncOperation,
        imported: YouTubeImport
    ) throws {
        guard operation.kind == .insert else { return }
        let candidates = (imported.items ?? []).filter {
            $0.youTubeId == operation.videoID && $0.playlistItemID == nil
        }
        let exact = candidates.filter { $0.order == operation.toPosition }
        guard exact.count == 1, let target = exact.first else {
            throw YouTubePlaylistSyncError.invalidSnapshot(
                "Inserted playlistItem id could not be claimed uniquely by position")
        }
        target.playlistItemID = playlistItemID
    }

    /// Persists first-seen remote identities before any Pull is accepted. The
    /// fresh context makes identity claiming its own transaction and prevents a
    /// later preview cancellation from discarding durable occurrence identity.
    func reconcileRemoteIdentities(
        importID: UUID, remote: YouTubePlaylistSnapshot
    ) throws -> YouTubePlaylistIdentityReconciler.Result {
        let context = ModelContext(modelContainer)
        guard let imported = try fetchImport(importID, context: context) else {
            throw YouTubePlaylistSyncError.importNotFound
        }
        let local = Self.localSnapshot(imported)
        let reconciliation = YouTubePlaylistIdentityReconciler.reconcile(
            local: local.items, remote: remote.items)
        guard !reconciliation.claims.isEmpty else { return reconciliation }

        let byID = Dictionary(uniqueKeysWithValues: (imported.items ?? []).map { ($0.id, $0) })
        for claim in reconciliation.claims {
            guard let item = byID[claim.localItemID] else {
                throw YouTubePlaylistSyncError.invalidSnapshot(
                    "Remote identity claim references a missing Local item")
            }
            if let existing = item.playlistItemID, !existing.isEmpty,
               existing != claim.remotePlaylistItemID {
                throw YouTubePlaylistSyncError.invalidSnapshot(
                    "Local item already owns another playlistItem id")
            }
            item.playlistItemID = claim.remotePlaylistItemID
        }
        try context.save()
        return reconciliation
    }

    private func fetchImport(_ id: UUID,
                             context: ModelContext) throws -> YouTubeImport? {
        let target = id
        let descriptor = FetchDescriptor<YouTubeImport>(predicate: #Predicate { $0.id == target })
        return try context.fetch(descriptor).first
    }

    private func fetchRevision(_ id: UUID,
                               context: ModelContext) throws -> YouTubePlaylistRevision? {
        let target = id
        let descriptor = FetchDescriptor<YouTubePlaylistRevision>(
            predicate: #Predicate { $0.id == target })
        return try context.fetch(descriptor).first
    }

    private func fetchBatch(_ id: UUID,
                            context: ModelContext) throws -> YouTubeSyncBatch? {
        let target = id
        let descriptor = FetchDescriptor<YouTubeSyncBatch>(
            predicate: #Predicate { $0.id == target })
        return try context.fetch(descriptor).first
    }

    private func fetchOperations(batchID: UUID,
                                 context: ModelContext) throws -> [YouTubeSyncOperation] {
        let target = batchID
        let descriptor = FetchDescriptor<YouTubeSyncOperation>(
            predicate: #Predicate { $0.batchID == target })
        return try context.fetch(descriptor)
    }
}
