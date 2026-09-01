import Foundation
import SwiftData
import Testing
@testable import Muses

@Suite("YouTube playlist sync — domain")
struct YouTubePlaylistSyncDomainTests {
    @Test("duplicate videos adopt playlist-item identities in occurrence order")
    func duplicateIdentityAdoption() {
        let local = [item(video: "same", order: 0), item(video: "same", order: 1)]
        let remote = [
            item(remote: "pi-1", video: "same", order: 0),
            item(remote: "pi-2", video: "same", order: 1)
        ]

        let adopted = YouTubePlaylistIdentityReconciler.adoptingRemoteItemIDs(
            local: local, remote: remote)

        #expect(adopted.map(\.playlistItemID) == ["pi-1", "pi-2"])
        #expect(Set(adopted.map(\.id)).count == 2)
    }

    @Test("duplicate identity adoption uses position and identified neighbours")
    func duplicateIdentityUsesNeighbours() {
        let anchor = item(remote: "pi-anchor", video: "anchor", order: 0)
        let firstDuplicate = item(video: "same", order: 1)
        let secondDuplicate = item(video: "same", order: 2)
        let tail = item(remote: "pi-tail", video: "tail", order: 3)
        let remote = [
            item(remote: "pi-anchor", video: "anchor", order: 0),
            item(remote: "pi-1", video: "same", order: 1),
            item(remote: "pi-2", video: "same", order: 2),
            item(remote: "pi-tail", video: "tail", order: 3),
        ]

        let result = YouTubePlaylistIdentityReconciler.reconcile(
            local: [anchor, firstDuplicate, secondDuplicate, tail], remote: remote)

        #expect(result.local.map(\.playlistItemID) ==
                ["pi-anchor", "pi-1", "pi-2", "pi-tail"])
        #expect(result.remote.map(\.id) == result.local.map(\.id))
        #expect(result.claims.map(\.localItemID) == [firstDuplicate.id, secondDuplicate.id])
    }

    @Test("unknown remote metadata is not a structural change")
    func unknownMetadataIsNotStructural() {
        let baseItem = item(remote: "pi-1", video: "video", order: 0,
                            title: "Known", artist: "Artist", durationMs: 123_000)
        var remoteItem = baseItem
        remoteItem.id = UUID()
        remoteItem.title = nil
        remoteItem.artist = nil
        remoteItem.durationMs = nil

        let base = snapshot([baseItem])
        let local = snapshot([baseItem])
        let remote = snapshot([remoteItem])
        let plan = YouTubePlaylistThreeWayMerge.plan(
            base: base, local: local, remote: remote)
        let merged = YouTubePlaylistSyncService.automaticallyMerged(
            base: base, local: local, remote: remote)

        #expect(plan.localOnlyChanges.isEmpty)
        #expect(plan.remoteOnlyChanges.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(base.fingerprint == remote.fingerprint)
        #expect(merged.items.first?.knownTitle == "Known")
        #expect(merged.items.first?.knownDurationMs == 123_000)
    }

    @Test("local insertion and remote move merge without hiding either change")
    func localInsertionAndRemoteMove() {
        let a = item(remote: "pi-a", video: "a", order: 0)
        let b = item(remote: "pi-b", video: "b", order: 1)
        let c = item(video: "c", order: 2)
        var remoteB = b
        remoteB.order = 0
        var remoteA = a
        remoteA.order = 1

        let base = snapshot([a, b])
        let local = snapshot([a, b, c])
        let remote = snapshot([remoteB, remoteA])
        let plan = YouTubePlaylistThreeWayMerge.plan(
            base: base, local: local, remote: remote)
        let merged = YouTubePlaylistSyncService.automaticallyMerged(
            base: base, local: local, remote: remote)

        #expect(plan.localOnlyChanges == [c.occurrenceKey])
        #expect(Set(plan.remoteOnlyChanges) == Set([a.occurrenceKey, b.occurrenceKey]))
        #expect(plan.conflicts.isEmpty)
        #expect(merged.normalizedItems.map(\.videoID) == ["b", "a", "c"])
    }

    @Test("three-way merge reports divergent ordering as an item conflict")
    func divergentMoveConflict() {
        let baseItem = item(remote: "pi-1", video: "video", order: 0)
        var localItem = baseItem
        localItem.order = 1
        var remoteItem = baseItem
        remoteItem.order = 2

        let plan = YouTubePlaylistThreeWayMerge.plan(
            base: snapshot([baseItem]),
            local: snapshot([localItem]),
            remote: snapshot([remoteItem]))

        #expect(plan.conflicts.count == 1)
        #expect(plan.conflicts.first?.kind == .divergentMove)
        #expect(plan.requiresResolution)
    }

    @Test("push planner keeps duplicate occurrences distinct")
    func pushPlannerKeepsDuplicatesDistinct() throws {
        let remote = snapshot([
            item(remote: "pi-1", video: "same", order: 0),
            item(remote: "pi-2", video: "same", order: 1)
        ])
        let desired = snapshot([
            item(remote: "pi-2", video: "same", order: 0),
            item(video: "same", order: 1)
        ])

        let operations = try YouTubePushPlanner.operations(remote: remote, desired: desired)

        #expect(operations.count == 2)
        #expect(operations[0].kind == .remove)
        #expect(operations[0].playlistItemID == "pi-1")
        #expect(operations[1].kind == .insert)
        #expect(operations[1].toPosition == 1)
    }

    @Test("incomplete Remote Shadow cannot produce a Push plan")
    func incompleteRemoteCannotPlanPush() {
        var remote = snapshot([
            item(remote: "pi-1", video: "same", order: 0)
        ])
        remote.pagination = .init(
            completeness: .incomplete(.init(.continuation)),
            pageCount: 1, nextPageToken: "next", itemCount: 1)

        #expect(throws: YouTubePushPlanningError.incompleteRemote) {
            _ = try YouTubePushPlanner.operations(
                remote: remote, desired: snapshot([]))
        }
    }

    @Test("legacy revisions without pagination proof are not trusted as complete")
    func legacyRevisionIsUntrusted() throws {
        let data = Data(#"{"playlistID":"legacy","title":"Legacy","capturedAt":0,"items":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(
            YouTubePlaylistSnapshot.self, from: data)

        #expect(decoded.pagination == nil)
        #expect(!decoded.isCompleteRemote)
        #expect(throws: YouTubePushPlanningError.incompleteRemote) {
            _ = try YouTubePushPlanner.operations(
                remote: decoded, desired: snapshot([]))
        }
    }

    @Test("journal idempotency key includes semantic target")
    func semanticJournalKey() {
        let batch = UUID()
        let importID = UUID()
        let first = YouTubeSyncOperation(
            importID: importID, accountChannelID: "channel",
            batchID: batch, sequence: 0, kind: .move,
            playlistItemID: "pi", videoID: "video", toPosition: 2)
        let changedTarget = YouTubeSyncOperation(
            importID: importID, accountChannelID: "channel",
            batchID: batch, sequence: 0, kind: .move,
            playlistItemID: "pi", videoID: "video", toPosition: 3)

        #expect(first.idempotencyKey != changedTarget.idempotencyKey)
        #expect(first.idempotencyKey.contains("pi"))
    }

    private func snapshot(_ items: [YouTubePlaylistItemSnapshot]) -> YouTubePlaylistSnapshot {
        .init(playlistID: "playlist", accountChannelID: "channel", title: "Test",
              capturedAt: Date(timeIntervalSince1970: 0), items: items,
              pagination: .init(completeness: .complete,
                                pageCount: items.isEmpty ? 1 : (items.count + 49) / 50,
                                nextPageToken: nil, itemCount: items.count))
    }

    private func item(remote: String? = nil, video: String, order: Int,
                      title: String? = "Song", artist: String? = "Artist",
                      durationMs: Int? = 1)
        -> YouTubePlaylistItemSnapshot {
        .init(id: UUID(), playlistItemID: remote, videoID: video,
              title: title, artist: artist, durationMs: durationMs,
              order: order, availability: .available)
    }
}

@Suite("YouTube playlist sync — complete pagination")
struct YouTubePlaylistPaginationTests {
    @Test("0, 1, 149, 150, 151, 200, and 5000 items read to completion")
    func boundaryCountsComplete() async {
        for total in [0, 1, 149, 150, 151, 200, 5_000] {
            let result = await Self.client(total: total).playlistItemsPaginated(
                playlistId: "PL")
            #expect(result.isComplete, "\(total) items must be complete")
            #expect(result.items.count == total)
            #expect(result.pageCount == max(1, (total + 49) / 50))
            #expect(result.nextPageToken == nil)
        }
    }

    @Test("safety ceiling returns an explicit continuation")
    func safetyCeilingIsIncomplete() async {
        let result = await Self.client(total: 200, maxPages: 3)
            .playlistItemsPaginated(playlistId: "PL")

        #expect(result.items.count == 150)
        #expect(result.pageCount == 3)
        #expect(result.nextPageToken == "p3")
        #expect(result.completeness == .incomplete(
            .init(.safetyLimit, detail: "3 pages")))
    }

    @Test("quota and parse failures retain the page continuation")
    func interruptionRetainsContinuation() async {
        let quota = await Self.client(total: 200, failurePage: 2,
                                      failure: .quotaExceeded)
            .playlistItemsPaginated(playlistId: "PL")
        #expect(quota.items.count == 100)
        #expect(quota.pageCount == 2)
        #expect(quota.nextPageToken == "p2")
        #expect(quota.completeness == .incomplete(.init(.quotaExceeded)))

        let resumed = await Self.client(total: 200).playlistItemsPaginated(
            playlistId: "PL", initialItems: quota.items,
            initialPageCount: quota.pageCount,
            nextPageToken: quota.nextPageToken)
        #expect(resumed.isComplete)
        #expect(resumed.items.count == 200)
        #expect(resumed.pageCount == 4)

        let parse = await Self.client(total: 200, failurePage: 2,
                                      failure: .parseFailure)
            .playlistItemsPaginated(playlistId: "PL")
        guard case .incomplete(let parseReason) = parse.completeness else {
            Issue.record("Expected an incomplete parse result")
            return
        }
        #expect(parseReason.kind == .parseFailure)
        #expect(parse.items.count == 100)
        #expect(parse.nextPageToken == "p2")
    }

    @Test("timeout and cancellation remain distinguishable")
    func timeoutAndCancellation() async {
        let timeout = await Self.client(total: 200, failurePage: 1,
                                        failure: .timedOut)
            .playlistItemsPaginated(playlistId: "PL")
        #expect(timeout.completeness == .incomplete(.init(.timedOut)))
        #expect(timeout.items.count == 50)
        #expect(timeout.nextPageToken == "p1")

        let slowClient = YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { _ in
                try await Task.sleep(for: .seconds(30))
                return (Self.pageData(total: 1, pageIndex: 0), Self.http(200))
            })
        let task = Task { await slowClient.playlistItemsPaginated(playlistId: "PL") }
        await Task.yield()
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.completeness == .incomplete(.init(.cancelled)))
        #expect(cancelled.items.isEmpty)
        #expect(cancelled.pageCount == 0)
    }

    enum Failure: Sendable {
        case quotaExceeded
        case parseFailure
        case timedOut
    }

    static func client(total: Int, maxPages: Int = 200,
                       failurePage: Int? = nil, failure: Failure? = nil)
        -> YouTubeDataAPIClient {
        YouTubeDataAPIClient(
            accessTokenProvider: { "AT" },
            http: { request in
                let index = pageIndex(request)
                if index == failurePage {
                    switch failure {
                    case .quotaExceeded:
                        let data = Data(#"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#.utf8)
                        return (data, http(403))
                    case .parseFailure:
                        return (Data("not-json".utf8), http(200))
                    case .timedOut:
                        throw URLError(.timedOut)
                    case nil:
                        break
                    }
                }
                return (pageData(total: total, pageIndex: index), http(200))
            },
            maxPages: maxPages)
    }

    static func pageIndex(_ request: URLRequest) -> Int {
        let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pageToken" })?.value
        guard let token, token.first == "p" else { return 0 }
        return Int(token.dropFirst()) ?? 0
    }

    static func pageData(total: Int, pageIndex: Int) -> Data {
        let start = pageIndex * 50
        let end = min(total, start + 50)
        let rows = start < end ? (start..<end).map { index in
            #"{"id":"pi-\#(index)","snippet":{"title":"Song \#(index)","channelTitle":"Artist"},"contentDetails":{"videoId":"v-\#(index)"}}"#
        }.joined(separator: ",") : ""
        let next = end < total ? #", "nextPageToken":"p\#(pageIndex + 1)""# : ""
        return Data(#"{"items":[\#(rows)]\#(next)}"#.utf8)
    }

    static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://www.googleapis.com")!,
                        statusCode: status, httpVersion: nil,
                        headerFields: nil)!
    }
}

@Suite("YouTube playlist sync — API errors")
struct YouTubePlaylistSyncAPIErrorTests {
    @Test("quota, rate limit, and network failures retain distinct retry semantics")
    func errorSemantics() {
        #expect(!YouTubeDataAPIClient.DataAPIError.quotaExceeded.isRetryable)
        #expect(YouTubeDataAPIClient.DataAPIError.rateLimited.isRetryable)
        #expect(YouTubeDataAPIClient.DataAPIError.network("offline").isRetryable)
        #expect(!YouTubeDataAPIClient.DataAPIError.unauthorized.isRetryable)
    }

    @Test("Google error envelope extracts quota reason")
    func googleQuotaReason() {
        let data = Data(#"{"error":{"code":403,"message":"quota","errors":[{"reason":"quotaExceeded"}]}}"#.utf8)
        #expect(YouTubeDataAPIClient.googleErrorReason(from: data) == "quotaExceeded")
    }
}

@MainActor
@Suite("YouTube playlist sync — recovery")
struct YouTubePlaylistSyncRecoveryTests {
    @Test("playlist overview exposes remote check and read-only state")
    func playlistOverviewStatus() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let checkedAt = Date(timeIntervalSince1970: 10_000)
        let imported = YouTubeImport(
            playlistId: "overview", url: "https://youtube.com/playlist?list=overview",
            title: "Overview", channel: "Owner", accountChannelID: "owner")
        imported.remoteCheckedAt = checkedAt
        imported.remoteWritable = false
        context.insert(imported)
        try context.save()

        let status = try makeService(container).overviewStatus(importID: imported.id)

        #expect(status.lastRemoteCheckAt == checkedAt)
        #expect(status.remoteWritable == false)
        #expect(status.pendingLocalChangeCount == 0)
        #expect(status.conflictCount == 0)
        #expect(!status.hasIncompleteRemote)
        #expect(!status.needsReview)
        #expect(status.errorMessage == nil)
    }

    @Test("first remote playlist-item identities are persisted before Pull")
    func firstRemoteIdentitiesArePersisted() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "identity", url: "https://youtube.com/playlist?list=identity",
            title: "Identity", channel: "Channel")
        let first = YouTubeImportItem(
            youTubeId: "same", title: "First", artist: "Artist", order: 0)
        let second = YouTubeImportItem(
            youTubeId: "same", title: "Second", artist: "Artist", order: 1)
        first.import_ = imported
        second.import_ = imported
        imported.items = [first, second]
        context.insert(imported)
        context.insert(first)
        context.insert(second)
        try context.save()

        let remote = snapshot(playlistID: imported.playlistId, items: [
            item(id: UUID(), remote: "pi-1", video: "same", order: 0),
            item(id: UUID(), remote: "pi-2", video: "same", order: 1),
        ])
        let result = try makeService(container).reconcileRemoteIdentities(
            importID: imported.id, remote: remote)

        let verify = ModelContext(container)
        let stored = try #require(
            verify.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect((stored.items ?? []).sorted { $0.order < $1.order }
            .map(\.playlistItemID) == ["pi-1", "pi-2"])
        #expect(result.remote.map(\.id) == [first.id, second.id])
    }

    @Test("accepted Pull keeps Local merge but advances Base only to Remote Shadow")
    func pullBaseRemainsRemoteShadow() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "base", url: "https://youtube.com/playlist?list=base",
            title: "Base", channel: "Channel", accountChannelID: "owner")
        let common = YouTubeImportItem(
            youTubeId: "a", title: "A", artist: "Artist", order: 0,
            playlistItemID: "pi-a")
        let localOnly = YouTubeImportItem(
            youTubeId: "c", title: "C", artist: "Artist", order: 1)
        common.import_ = imported
        localOnly.import_ = imported
        imported.items = [common, localOnly]
        context.insert(imported)
        context.insert(common)
        context.insert(localOnly)

        let remote = snapshot(playlistID: imported.playlistId, items: [
            item(id: common.id, remote: "pi-a", video: "a", order: 0),
        ])
        let remoteData = try JSONEncoder().encode(remote)
        let remoteRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .remoteShadow,
            snapshotData: remoteData, fingerprint: remote.fingerprint)
        let baseRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .base,
            snapshotData: remoteData, fingerprint: remote.fingerprint)
        let local = YouTubePlaylistSyncService.localSnapshot(imported)
        let localRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .local,
            snapshotData: try JSONEncoder().encode(local), fingerprint: local.fingerprint)
        imported.baseRevisionID = baseRevision.id
        imported.remoteShadowRevisionID = remoteRevision.id
        context.insert(remoteRevision)
        context.insert(baseRevision)
        context.insert(localRevision)
        try context.save()

        let plan = YouTubePlaylistThreeWayMerge.plan(
            base: remote, local: local, remote: remote)
        let preview = YouTubePullPreview(
            importID: imported.id, baseRevisionID: baseRevision.id,
            localRevisionID: localRevision.id, remoteRevisionID: remoteRevision.id,
            base: remote, local: local, remote: remote,
            automaticResult: local, mergePlan: plan)
        let service = makeService(container)
        try service.applyPull(preview)

        let verify = ModelContext(container)
        let stored = try #require(
            verify.fetch(FetchDescriptor<YouTubeImport>()).first)
        let baseID = try #require(stored.baseRevisionID)
        let verifiedBaseRevision = try #require(
            verify.fetch(FetchDescriptor<YouTubePlaylistRevision>())
                .first { $0.id == baseID })
        let acceptedBase = try verifiedBaseRevision.decodeSnapshot()
        let currentLocal = YouTubePlaylistSyncService.localSnapshot(stored)
        let pending = YouTubePlaylistThreeWayMerge.plan(
            base: acceptedBase, local: currentLocal, remote: acceptedBase)

        #expect(acceptedBase.normalizedItems.map(\.videoID) == ["a"])
        #expect(currentLocal.normalizedItems.map(\.videoID) == ["a", "c"])
        #expect(pending.localOnlyChanges == [localOnly.id.uuidString.lowercased()]
            .map { "local:\($0)" })
    }

    @Test("Pull preview is rejected after Local changes")
    func stalePullPreviewIsRejected() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "stale", url: "https://youtube.com/playlist?list=stale",
            title: "Stale", channel: "Channel", accountChannelID: "owner")
        let common = YouTubeImportItem(
            youTubeId: "a", title: "A", artist: "Artist", order: 0,
            playlistItemID: "pi-a")
        common.import_ = imported
        imported.items = [common]
        context.insert(imported)
        context.insert(common)

        let remote = snapshot(playlistID: imported.playlistId, items: [
            item(id: common.id, remote: "pi-a", video: "a", order: 0),
        ])
        let local = YouTubePlaylistSyncService.localSnapshot(imported)
        let remoteData = try JSONEncoder().encode(remote)
        let localData = try JSONEncoder().encode(local)
        let baseRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .base,
            snapshotData: remoteData, fingerprint: remote.fingerprint)
        let localRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .local,
            snapshotData: localData, fingerprint: local.fingerprint)
        let remoteRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .remoteShadow,
            snapshotData: remoteData, fingerprint: remote.fingerprint)
        imported.baseRevisionID = baseRevision.id
        imported.remoteShadowRevisionID = remoteRevision.id
        context.insert(baseRevision)
        context.insert(localRevision)
        context.insert(remoteRevision)
        try context.save()

        let preview = YouTubePullPreview(
            importID: imported.id, baseRevisionID: baseRevision.id,
            localRevisionID: localRevision.id, remoteRevisionID: remoteRevision.id,
            base: remote, local: local, remote: remote, automaticResult: local,
            mergePlan: YouTubePlaylistThreeWayMerge.plan(
                base: remote, local: local, remote: remote))
        let added = YouTubeImportItem(
            youTubeId: "new", title: "New", artist: "Artist", order: 1)
        added.import_ = imported
        imported.items = [common, added]
        context.insert(added)
        try context.save()

        do {
            try makeService(container).applyPull(preview)
            Issue.record("Expected stale Local preview rejection")
        } catch let error as YouTubePlaylistSyncError {
            #expect(error == .invalidSnapshot("Local changed; preview again"))
        }
    }

    @Test("incomplete Remote Shadow cannot delete Local rows through Pull")
    func incompleteRemoteCannotApplyPull() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "incomplete", url: "https://youtube.com/playlist?list=incomplete",
            title: "Incomplete", channel: "Channel", accountChannelID: "owner")
        let existing = YouTubeImportItem(
            youTubeId: "keep", title: "Keep", artist: "Artist", order: 0,
            playlistItemID: "pi-keep")
        existing.import_ = imported
        imported.items = [existing]
        context.insert(imported)
        context.insert(existing)

        let base = snapshot(playlistID: imported.playlistId, items: [
            item(id: existing.id, remote: "pi-keep", video: "keep", order: 0)
        ])
        var partialRemote = snapshot(playlistID: imported.playlistId, items: [])
        partialRemote.pagination = .init(
            completeness: .incomplete(.init(.continuation)),
            pageCount: 1, nextPageToken: "next", itemCount: 0)
        let local = YouTubePlaylistSyncService.localSnapshot(imported)
        let baseRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .base,
            snapshotData: try JSONEncoder().encode(base), fingerprint: base.fingerprint)
        let localRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .local,
            snapshotData: try JSONEncoder().encode(local), fingerprint: local.fingerprint)
        let remoteRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: "owner", kind: .remoteShadow,
            snapshotData: try JSONEncoder().encode(partialRemote),
            fingerprint: partialRemote.fingerprint)
        imported.baseRevisionID = baseRevision.id
        imported.remoteShadowRevisionID = remoteRevision.id
        context.insert(baseRevision)
        context.insert(localRevision)
        context.insert(remoteRevision)
        try context.save()

        let preview = YouTubePullPreview(
            importID: imported.id, baseRevisionID: baseRevision.id,
            localRevisionID: localRevision.id, remoteRevisionID: remoteRevision.id,
            base: base, local: local, remote: partialRemote,
            automaticResult: partialRemote,
            mergePlan: YouTubePlaylistThreeWayMerge.plan(
                base: base, local: local, remote: partialRemote))
        #expect(throws: YouTubePlaylistSyncError.invalidSnapshot(
            "Pull requires a complete Remote Shadow")) {
            try makeService(container).applyPull(preview)
        }

        let verify = ModelContext(container)
        let stored = try #require(
            verify.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect((stored.items ?? []).map(\.youTubeId) == ["keep"])
    }

    @Test("partial pages persist without publication and the next check resumes")
    func partialPagesPersistAndResume() async throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "PL", url: "https://youtube.com/playlist?list=PL",
            title: "Large", channel: "Channel", accountChannelID: "owner")
        context.insert(imported)
        try context.save()

        let limitedAccount = try await connectedAccount(total: 200, maxPages: 3)
        let limitedService = YouTubePlaylistSyncService(
            modelContainer: container, account: limitedAccount)
        do {
            _ = try await limitedService.checkRemote(importID: imported.id)
            Issue.record("Expected an incomplete safety-limit result")
        } catch let error as YouTubePlaylistSyncError {
            #expect(error == .incompleteRemote(
                itemCount: 150, pageCount: 3,
                reason: .init(.safetyLimit, detail: "3 pages")))
            #expect(error.localizedDescription.contains("150"))
        }

        let partialContext = ModelContext(container)
        let partialImport = try #require(
            partialContext.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect(partialImport.remoteShadowRevisionID == nil)
        let revisions = try partialContext.fetch(
            FetchDescriptor<YouTubePlaylistRevision>())
        let partialRevision = try #require(
            revisions.first { $0.kind == .remotePartial })
        let partial = try partialRevision.decodeSnapshot()
        #expect(partial.items.count == 150)
        #expect(partial.pagination?.pageCount == 3)
        #expect(partial.pagination?.nextPageToken == "p3")

        let recorder = PlaylistPageTokenRecorder()
        let completeAccount = try await connectedAccount(
            total: 200, maxPages: 200, recorder: recorder)
        let completeService = YouTubePlaylistSyncService(
            modelContainer: container, account: completeAccount)
        let preview = try await completeService.checkRemote(importID: imported.id)

        #expect(preview.remote.items.count == 200)
        #expect(preview.remote.isCompleteRemote)
        #expect(preview.remote.pagination?.pageCount == 4)
        #expect(await recorder.values() == ["p3"])
        let finalRevisions = try ModelContext(container).fetch(
            FetchDescriptor<YouTubePlaylistRevision>())
        #expect(finalRevisions.contains { $0.kind == .remoteShadow })
        #expect(!finalRevisions.contains { $0.kind == .remotePartial })
    }

    @Test("cancelling a check preserves its last completed page")
    func cancellationPersistsContinuation() async throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "PL", url: "https://youtube.com/playlist?list=PL",
            title: "Cancelable", channel: "Channel", accountChannelID: "owner")
        context.insert(imported)
        try context.save()

        let recorder = PlaylistPageTokenRecorder()
        let account = try await connectedAccount(
            total: 100, maxPages: 200, recorder: recorder, stallPage: 1)
        let service = YouTubePlaylistSyncService(
            modelContainer: container, account: account)
        let task = Task { try await service.checkRemote(importID: imported.id) }
        await recorder.waitUntilRecorded("p1")
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the remote check to stop after cancellation")
        } catch let error as YouTubePlaylistSyncError {
            #expect(error == .incompleteRemote(
                itemCount: 50, pageCount: 1, reason: .init(.cancelled)))
        }

        let revisions = try ModelContext(container).fetch(
            FetchDescriptor<YouTubePlaylistRevision>())
        let partialRevision = try #require(
            revisions.first { $0.kind == .remotePartial })
        let partial = try partialRevision.decodeSnapshot()
        #expect(partial.items.count == 50)
        #expect(partial.pagination?.nextPageToken == "p1")
        #expect(partial.pagination?.completeness == .incomplete(.init(.cancelled)))
        #expect(!revisions.contains { $0.kind == .remoteShadow })
    }

    @Test("Push resumes every journal transition without replaying an insert")
    func pushTransitionFaultsDoNotReplayInsert() async throws {
        let faultPoints: [YouTubePushFaultPoint] = [
            .afterBatchStarted,
            .afterOperationStarted(0),
            .afterOperationRemoteObserved(0),
            .afterOperationLocallyCommitted(0),
            .afterBatchRemoteObserved,
            .afterBatchLocallyCommitted,
        ]

        for point in faultPoints {
            let fixture = try await pushFixture()
            var injected = false
            let interrupted = YouTubePlaylistSyncService(
                modelContainer: fixture.container, account: fixture.account,
                pushExecutionPolicy: .enabledForTesting,
                pushFaultInjector: { observed in
                    if !injected, observed == point {
                        injected = true
                        throw InjectedPushFault()
                    }
                })
            await #expect(throws: InjectedPushFault.self) {
                try await interrupted.resumePush(batchID: fixture.preview.batchID)
            }

            let resumed = YouTubePlaylistSyncService(
                modelContainer: fixture.container, account: fixture.account,
                pushExecutionPolicy: .enabledForTesting)
            try await resumed.resumePush(batchID: fixture.preview.batchID)

            #expect(await fixture.server.insertRequestCount() == 1,
                    "\(point) replayed the insert")
            #expect(await fixture.server.videoIDs() == ["a", "b"])
            let context = ModelContext(fixture.container)
            #expect(try context.fetch(FetchDescriptor<YouTubeSyncBatch>())
                .first?.state == .locallyCommitted)
            #expect(try context.fetch(FetchDescriptor<YouTubeSyncOperation>())
                .first?.state == .locallyCommitted)
        }
    }

    @Test("remote change after preview invalidates Push before the first write")
    func remoteChangeInvalidatesPreview() async throws {
        let fixture = try await pushFixture()
        await fixture.server.appendExternal(videoID: "external")
        let service = YouTubePlaylistSyncService(
            modelContainer: fixture.container, account: fixture.account,
            pushExecutionPolicy: .enabledForTesting)

        await #expect(throws: YouTubePlaylistSyncError.remoteChangedSincePreview) {
            try await service.resumePush(batchID: fixture.preview.batchID)
        }

        #expect(await fixture.server.insertRequestCount() == 0)
        let batch = try ModelContext(fixture.container)
            .fetch(FetchDescriptor<YouTubeSyncBatch>()).first
        #expect(batch?.state == .needsReview)
    }

    @Test("timeout after remote commit is reconciled and never replayed")
    func timeoutAfterCommitIsReconciled() async throws {
        let fixture = try await pushFixture()
        await fixture.server.setNextInsertBehavior(.timeoutAfterCommit)
        let service = YouTubePlaylistSyncService(
            modelContainer: fixture.container, account: fixture.account,
            pushExecutionPolicy: .enabledForTesting)
        await #expect(throws: YouTubeDataAPIClient.DataAPIError.self) {
            try await service.resumePush(batchID: fixture.preview.batchID)
        }

        try await service.resumePush(batchID: fixture.preview.batchID)

        #expect(await fixture.server.insertRequestCount() == 1)
        #expect(await fixture.server.videoIDs() == ["a", "b"])
    }

    @Test("empty insert response is recovered from the complete remote shadow")
    func emptyInsertResponseIsRecovered() async throws {
        let fixture = try await pushFixture()
        await fixture.server.setNextInsertBehavior(.emptyIDAfterCommit)
        let service = YouTubePlaylistSyncService(
            modelContainer: fixture.container, account: fixture.account,
            pushExecutionPolicy: .enabledForTesting)
        await #expect(throws: YouTubePlaylistSyncError.invalidSnapshot(
            "Insert returned no playlistItem id")) {
            try await service.resumePush(batchID: fixture.preview.batchID)
        }

        try await service.resumePush(batchID: fixture.preview.batchID)
        #expect(await fixture.server.insertRequestCount() == 1)
    }

    @Test("rate limit before commit can resume only after proving no mutation")
    func rateLimitBeforeCommitCanResumeSafely() async throws {
        let fixture = try await pushFixture()
        await fixture.server.setNextInsertBehavior(.rateLimitBeforeCommit)
        let service = YouTubePlaylistSyncService(
            modelContainer: fixture.container, account: fixture.account,
            pushExecutionPolicy: .enabledForTesting)
        await #expect(throws: YouTubeDataAPIClient.DataAPIError.rateLimited) {
            try await service.resumePush(batchID: fixture.preview.batchID)
        }

        try await service.resumePush(batchID: fixture.preview.batchID)
        #expect(await fixture.server.insertRequestCount() == 2)
        #expect(await fixture.server.videoIDs() == ["a", "b"])
    }

    @Test("production Push switch remains off even with broad OAuth scope")
    func productionPushSwitchDefaultsOff() async throws {
        let fixture = try await pushFixture()
        let service = YouTubePlaylistSyncService(
            modelContainer: fixture.container, account: fixture.account)
        await #expect(throws: YouTubePlaylistSyncError.remoteWritesDisabled) {
            try await service.resumePush(batchID: fixture.preview.batchID)
        }
        #expect(await fixture.server.insertRequestCount() == 0)
    }

    @Test("Recently Deleted expires after 30 days without deleting Track rows")
    func expiredRecentlyDeletedIsPurgedLocally() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expired = YouTubeImport(
            playlistId: "expired", url: "https://youtube.com/playlist?list=expired",
            title: "Expired", channel: "Channel")
        expired.deletedAt = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let track = Track(title: "Song", artist: "Artist", youTubeId: "video")
        let item = YouTubeImportItem(
            youTubeId: "video", title: "Song", artist: "Artist", durationMs: 1, order: 0)
        item.track = track
        expired.items = [item]
        let recent = YouTubeImport(
            playlistId: "recent", url: "https://youtube.com/playlist?list=recent",
            title: "Recent", channel: "Channel")
        recent.deletedAt = now.addingTimeInterval(-29 * 24 * 60 * 60)
        context.insert(expired)
        context.insert(recent)
        context.insert(track)
        context.insert(item)
        try context.save()

        let service = makeService(container)
        #expect(try service.purgeExpiredRecentlyDeleted(now: now) == 1)

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<YouTubeImport>()).map(\.playlistId) == ["recent"])
        #expect(try verify.fetch(FetchDescriptor<Track>()).map(\.youTubeId) == ["video"])
    }

    @Test("pinned revisions survive beyond the Recently Deleted window")
    func pinnedRevisionKeepsHiddenTombstone() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let imported = YouTubeImport(
            playlistId: "pinned", url: "https://youtube.com/playlist?list=pinned",
            title: "Pinned", channel: "Channel")
        imported.deletedAt = now.addingTimeInterval(-90 * 24 * 60 * 60)
        context.insert(imported)
        try context.save()

        let service = makeService(container)
        _ = try service.saveLocalRevision(importID: imported.id, pinned: true)
        #expect(try service.purgeExpiredRecentlyDeleted(now: now) == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<YouTubeImport>()).count == 1)
        #expect(!YouTubePlaylistSyncService.isWithinRecentlyDeletedRetention(imported, now: now))
    }

    @Test("revision comparison preserves duplicate occurrence identity and ordered changes")
    func revisionComparisonIsOccurrenceAware() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "history", url: "https://youtube.com/playlist?list=history",
            title: "History", channel: "Channel")
        context.insert(imported)

        let first = item(id: UUID(), remote: "pi-1", video: "same", order: 0)
        let second = item(id: UUID(), remote: "pi-2", video: "same", order: 1)
        let removed = item(id: UUID(), remote: "pi-old", video: "old", order: 2)
        let inserted = item(id: UUID(), remote: "pi-new", video: "new", order: 1)
        var movedSecond = second
        movedSecond.order = 0
        var movedFirst = first
        movedFirst.order = 2
        let older = snapshot(playlistID: imported.playlistId,
                             items: [first, second, removed])
        let newer = snapshot(playlistID: imported.playlistId,
                             items: [movedSecond, inserted, movedFirst])
        let oldRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: nil, kind: .local,
            snapshotData: try JSONEncoder().encode(older), fingerprint: older.fingerprint)
        let newRevision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: nil, kind: .local,
            snapshotData: try JSONEncoder().encode(newer), fingerprint: newer.fingerprint)
        context.insert(oldRevision)
        context.insert(newRevision)
        try context.save()

        let service = makeService(container)
        let comparison = try service.compareRevisions(
            olderID: oldRevision.id, newerID: newRevision.id)

        #expect(comparison.insertedCount == 1)
        #expect(comparison.removedCount == 1)
        #expect(comparison.movedCount == 2)
        #expect(comparison.changes.filter { $0.kind == .moved }
            .map(\.item.playlistItemID).compactMap { $0 } == ["pi-2", "pi-1"])
    }

    @Test("restore saves a before-restore recovery point and never creates a Push journal")
    func restoreCreatesRecoveryPointWithoutPush() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "restore", url: "https://youtube.com/playlist?list=restore",
            title: "Restore", channel: "Channel")
        let currentA = YouTubeImportItem(
            youTubeId: "a", title: "A", artist: "Artist", order: 0,
            playlistItemID: "pi-a")
        let currentB = YouTubeImportItem(
            youTubeId: "b", title: "B", artist: "Artist", order: 1,
            playlistItemID: "pi-b")
        currentA.import_ = imported
        currentB.import_ = imported
        imported.items = [currentA, currentB]
        context.insert(imported)
        context.insert(currentA)
        context.insert(currentB)

        let target = snapshot(playlistID: imported.playlistId, items: [
            item(id: currentB.id, remote: "pi-b", video: "b", order: 0),
        ])
        let revision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: nil, kind: .beforePull,
            snapshotData: try JSONEncoder().encode(target), fingerprint: target.fingerprint)
        context.insert(revision)
        try context.save()

        let service = makeService(container)
        try service.restore(revisionID: revision.id)

        let verify = ModelContext(container)
        let stored = try #require(verify.fetch(FetchDescriptor<YouTubeImport>()).first)
        #expect((stored.items ?? []).sorted { $0.order < $1.order }.map(\.youTubeId) == ["b"])
        let kinds = try verify.fetch(FetchDescriptor<YouTubePlaylistRevision>()).map(\.kind)
        #expect(kinds.contains(.beforeRestore))
        #expect(kinds.contains(.restored))
        #expect(try verify.fetch(FetchDescriptor<YouTubeSyncBatch>()).isEmpty)
        #expect(try verify.fetch(FetchDescriptor<YouTubeSyncOperation>()).isEmpty)
    }

    @Test("restore as copy creates a detached Muses playlist with YouTube-backed tracks")
    func restoreAsCopyIsDetached() throws {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "copy", url: "https://youtube.com/playlist?list=copy",
            title: "Copy Source", channel: "Channel")
        context.insert(imported)
        let target = snapshot(playlistID: imported.playlistId, items: [
            item(id: UUID(), remote: "pi-a", video: "a", order: 0),
            item(id: UUID(), remote: "pi-b", video: "b", order: 1),
        ])
        let revision = YouTubePlaylistRevision(
            importID: imported.id, accountChannelID: nil, kind: .local,
            snapshotData: try JSONEncoder().encode(target), fingerprint: target.fingerprint)
        context.insert(revision)
        try context.save()

        let playlistID = try makeService(container).restoreAsCopy(
            revisionID: revision.id, name: "Recovered")

        let verify = ModelContext(container)
        let playlist = try #require(verify.fetch(FetchDescriptor<Playlist>())
            .first { $0.id == playlistID })
        #expect(playlist.name == "Recovered")
        #expect((playlist.items ?? []).sorted { $0.order < $1.order }
            .compactMap { $0.track?.youTubeId } == ["a", "b"])
        #expect(try verify.fetch(FetchDescriptor<YouTubeImport>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<YouTubeSyncBatch>()).isEmpty)
    }

    private func makeService(_ container: ModelContainer) -> YouTubePlaylistSyncService {
        let session = GoogleOAuthSession(keychain: InMemoryKeychain())
        return YouTubePlaylistSyncService(
            modelContainer: container,
            account: YouTubeAccountService(session: session))
    }

    private func pushFixture() async throws -> (
        container: ModelContainer,
        account: YouTubeAccountService,
        server: PushAPIStub,
        preview: YouTubePushPreview
    ) {
        let container = try makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let imported = YouTubeImport(
            playlistId: "PL", url: "https://youtube.com/playlist?list=PL",
            title: "Push", channel: "Owner", accountChannelID: "owner")
        let existing = YouTubeImportItem(
            youTubeId: "a", title: "A", artist: "Artist", order: 0,
            playlistItemID: "pi-a")
        let inserted = YouTubeImportItem(
            youTubeId: "b", title: "B", artist: "Artist", order: 1)
        existing.import_ = imported
        inserted.import_ = imported
        imported.items = [existing, inserted]
        context.insert(imported)
        context.insert(existing)
        context.insert(inserted)
        try context.save()

        let server = PushAPIStub(rows: [
            .init(id: "pi-a", videoID: "a")
        ])
        let session = GoogleOAuthSession(keychain: InMemoryKeychain())
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "client", clientSecret: "secret",
            redirectURI: "muses:/oauth", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: .now.addingTimeInterval(3_600),
            scope: GoogleOAuthConfig.manageScope))
        let account = YouTubeAccountService(session: session, clientFactory: { _ in
            YouTubeDataAPIClient(
                accessTokenProvider: { "AT" },
                http: { request in try await server.respond(to: request) })
        })
        await account.refresh()
        let planner = YouTubePlaylistSyncService(
            modelContainer: container, account: account)
        let preview = try await planner.preparePush(importID: imported.id)
        return (container, account, server, preview)
    }

    private func connectedAccount(
        total: Int,
        maxPages: Int,
        recorder: PlaylistPageTokenRecorder? = nil,
        stallPage: Int? = nil
    ) async throws -> YouTubeAccountService {
        let session = GoogleOAuthSession(keychain: InMemoryKeychain())
        try session.saveConfig(GoogleOAuthConfig(
            clientID: "client", clientSecret: "secret",
            redirectURI: "http://127.0.0.1:53682/", scopes: []))
        try session.storeTokens(OAuthTokenSet(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(3_600),
            scope: GoogleOAuthConfig.manageScope))
        let account = YouTubeAccountService(session: session, clientFactory: { _ in
            YouTubeDataAPIClient(
                accessTokenProvider: { "AT" },
                http: { request in
                    let path = request.url?.path ?? ""
                    if path.hasSuffix("/channels") {
                        return (Data(#"{"items":[{"id":"owner","snippet":{"title":"Owner"}}]}"#.utf8),
                                YouTubePlaylistPaginationTests.http(200))
                    }
                    if path.hasSuffix("/playlists") {
                        return (Data(#"{"items":[{"id":"PL","snippet":{"title":"Large"},"contentDetails":{"itemCount":200}}]}"#.utf8),
                                YouTubePlaylistPaginationTests.http(200))
                    }
                    if path.hasSuffix("/playlistItems") {
                        let index = YouTubePlaylistPaginationTests.pageIndex(request)
                        let token = index == 0 ? "first" : "p\(index)"
                        await recorder?.record(token)
                        if index == stallPage {
                            try await Task.sleep(for: .seconds(30))
                        }
                        return (YouTubePlaylistPaginationTests.pageData(
                                    total: total, pageIndex: index),
                                YouTubePlaylistPaginationTests.http(200))
                    }
                    return (Data(#"{"items":[]}"#.utf8),
                            YouTubePlaylistPaginationTests.http(200))
                },
                maxPages: maxPages)
        })
        await account.refresh()
        #expect(account.activeChannelID == "owner")
        #expect(account.ownsPlaylist("PL"))
        return account
    }

    private func snapshot(playlistID: String,
                          items: [YouTubePlaylistItemSnapshot]) -> YouTubePlaylistSnapshot {
        .init(playlistID: playlistID, accountChannelID: "owner", title: "Test",
              capturedAt: Date(timeIntervalSince1970: 0), items: items,
              pagination: .init(completeness: .complete,
                                pageCount: items.isEmpty ? 1 : (items.count + 49) / 50,
                                nextPageToken: nil, itemCount: items.count))
    }

    private func item(id: UUID, remote: String? = nil, video: String, order: Int)
        -> YouTubePlaylistItemSnapshot {
        .init(id: id, playlistItemID: remote, videoID: video,
              title: "Song", artist: "Artist", durationMs: 1,
              order: order, availability: .available)
    }
}

private actor PlaylistPageTokenRecorder {
    private var tokens: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ token: String) {
        tokens.append(token)
        for waiter in waiters.removeValue(forKey: token) ?? [] {
            waiter.resume()
        }
    }

    func waitUntilRecorded(_ token: String) async {
        guard !tokens.contains(token) else { return }
        await withCheckedContinuation { continuation in
            waiters[token, default: []].append(continuation)
        }
    }

    func values() -> [String] { tokens }
}

private struct InjectedPushFault: Error {}

private actor PushAPIStub {
    struct Row: Sendable, Equatable {
        let id: String
        let videoID: String
    }

    enum InsertBehavior: Sendable {
        case success
        case timeoutAfterCommit
        case emptyIDAfterCommit
        case rateLimitBeforeCommit
    }

    private var rows: [Row]
    private var nextInsertBehavior: InsertBehavior = .success
    private var insertRequests = 0
    private var generatedIDs = 0

    init(rows: [Row]) { self.rows = rows }

    func setNextInsertBehavior(_ behavior: InsertBehavior) {
        nextInsertBehavior = behavior
    }

    func appendExternal(videoID: String) {
        generatedIDs += 1
        rows.append(.init(id: "pi-external-\(generatedIDs)", videoID: videoID))
    }

    func insertRequestCount() -> Int { insertRequests }
    func videoIDs() -> [String] { rows.map(\.videoID) }

    func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if path.hasSuffix("/channels") {
            return response(#"{"items":[{"id":"owner","snippet":{"title":"Owner"}}]}"#)
        }
        if path.hasSuffix("/playlists") {
            return response(#"{"items":[{"id":"PL","snippet":{"title":"Push"},"contentDetails":{"itemCount":1}}]}"#)
        }
        if path.hasSuffix("/subscriptions") || path.hasSuffix("/videos") {
            return response(#"{"items":[]}"#)
        }
        guard path.hasSuffix("/playlistItems") else {
            return response(#"{"items":[]}"#)
        }

        if method == "GET" {
            let values = rows.map { row in
                #"{"id":"\#(row.id)","snippet":{"title":"\#(row.videoID)","channelTitle":"Artist"},"contentDetails":{"videoId":"\#(row.videoID)"}}"#
            }.joined(separator: ",")
            return response(#"{"items":[\#(values)]}"#)
        }

        if method == "POST" {
            insertRequests += 1
            let behavior = nextInsertBehavior
            nextInsertBehavior = .success
            if behavior == .rateLimitBeforeCommit {
                return (Data(), Self.http(429))
            }
            let payload = try Self.insertPayload(from: request)
            generatedIDs += 1
            let id = "pi-new-\(generatedIDs)"
            rows.insert(.init(id: id, videoID: payload.videoID),
                        at: min(payload.position, rows.count))
            if behavior == .timeoutAfterCommit { throw URLError(.timedOut) }
            if behavior == .emptyIDAfterCommit { return response("{}") }
            return response(#"{"id":"\#(id)"}"#, status: 201)
        }

        if method == "DELETE" {
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value
            rows.removeAll { $0.id == id }
            return (Data(), Self.http(204))
        }

        return response("{}")
    }

    private static func insertPayload(from request: URLRequest) throws
        -> (videoID: String, position: Int) {
        let value = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        guard let root = value as? [String: Any],
              let snippet = root["snippet"] as? [String: Any],
              let resource = snippet["resourceId"] as? [String: Any],
              let videoID = resource["videoId"] as? String else {
            throw YouTubeDataAPIClient.DataAPIError.parse("invalid write body")
        }
        return (videoID, snippet["position"] as? Int ?? Int.max)
    }

    private func response(_ body: String, status: Int = 200)
        -> (Data, HTTPURLResponse) {
        (Data(body.utf8), Self.http(status))
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://www.googleapis.com")!,
                        statusCode: status, httpVersion: nil,
                        headerFields: nil)!
    }
}
