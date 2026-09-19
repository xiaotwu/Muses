import Foundation
import SwiftData
import Testing
@testable import Muses

/// Opt-in destructive acceptance test for the R001 whole-playlist resource
/// boundary. The test only ever deletes the playlist ID returned by its own
/// create request, and only after an independent owned-playlist read-back.
@MainActor
@Suite("YouTube playlist resource — live acceptance")
struct YouTubePlaylistResourceLiveTests {
    private enum ValidationError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let message): message
            }
        }
    }

    @Test(
        "R001 creates, rereads, deletes, and confirms absence",
        .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_REAL_RESOURCE_VALIDATION"] == "1")
    )
    func createDeleteClosedLoop() async throws {
        let protectedPlaylistID = "PLVRppllwHcDw"
        let title = "Muses R001 Resource Validation \(UUID().uuidString.prefix(8))"
        let description = "Disposable private playlist for Muses R001 acceptance validation."
        let session = GoogleOAuthSession(keychain: KeychainStore())
        let account = YouTubeAccountService(session: session)
        await account.refreshPersistedConnectionIfNeeded()

        guard account.isConnected,
              account.canManagePlaylists,
              let channel = account.account?.channel,
              let client = account.dataAPIClient(),
              let writer = account.playlistWriter() else {
            throw ValidationError.failed(
                "A connected YouTube account with playlist management access is required: "
                    + (account.lastError ?? "account snapshot unavailable"))
        }

        let before = try await client.myPlaylists()
        let beforeIDs = Set(before.map(\.id))
        guard beforeIDs.contains(protectedPlaylistID) else {
            throw ValidationError.failed(
                "Protected validation playlist is not owned by the active channel")
        }

        let container = try makeModelContainer(inMemory: true)
        let service = YouTubePlaylistSyncService(
            modelContainer: container,
            account: account,
            pushExecutionPolicy: .userApproved)
        let create = try service.prepareCreatePlaylist(
            title: title, description: description, privacy: .private)

        do {
            let importID = try await service.resumeCreatePlaylist(
                operationID: create.id, userConfirmed: true)
            let created = try createdImport(importID, container: container)
            let playlistID = created.playlistId
            guard !playlistID.isEmpty, !beforeIDs.contains(playlistID) else {
                throw ValidationError.failed(
                    "Create did not produce a new exact playlist ID")
            }

            let createReadback = try await client.myPlaylists()
            guard let remote = createReadback.first(where: { $0.id == playlistID }),
                  remote.title == title,
                  remote.privacy == .private,
                  remote.itemCount == 0 else {
                throw ValidationError.failed(
                    "Created playlist failed exact ID/title/privacy/item-count read-back")
            }
            try requireResourceJournal(
                operationID: create.id, kind: .create,
                state: .locallyCommitted, playlistID: playlistID,
                channelID: channel.id, container: container)

            let deletion = try await service.prepareDeletePlaylist(importID: importID)
            guard deletion.playlistID == playlistID,
                  deletion.accountChannelID == channel.id,
                  deletion.playlistTitle == title,
                  deletion.itemCount == 0 else {
                throw ValidationError.failed(
                    "Delete preview did not preserve the exact empty created target")
            }
            try await service.resumeDeletePlaylist(
                operationID: deletion.id, userConfirmed: true)

            let after = try await client.myPlaylists()
            let afterIDs = Set(after.map(\.id))
            guard afterIDs == beforeIDs,
                  afterIDs.contains(protectedPlaylistID),
                  !afterIDs.contains(playlistID) else {
                throw ValidationError.failed(
                    "Server read-back did not restore the pre-validation playlist set")
            }
            try requireResourceJournal(
                operationID: deletion.id, kind: .delete,
                state: .locallyCommitted, playlistID: playlistID,
                channelID: channel.id, container: container)

            let finalImport = try createdImport(importID, container: container)
            guard finalImport.deletedAt != nil,
                  finalImport.remoteWritable != true,
                  finalImport.remoteWriteApprovedAt == nil else {
                throw ValidationError.failed(
                    "Local delete commit did not close the resource lifecycle")
            }

            print("R001 LIVE PASS channel=\(channel.id) playlist=\(playlistID) "
                  + "privacy=private items=0 createReadback=present "
                  + "deleteReadback=absent protectedPlaylist=present")
        } catch {
            try await removeCreatedPlaylistIfNecessary(
                operationID: create.id, expectedTitle: title,
                protectedIDs: beforeIDs, client: client,
                writer: writer, container: container)
            throw error
        }
    }

    private func createdImport(
        _ importID: UUID, container: ModelContainer
    ) throws -> YouTubeImport {
        let context = ModelContext(container)
        guard let imported = try context.fetch(FetchDescriptor<YouTubeImport>())
            .first(where: { $0.id == importID }) else {
            throw ValidationError.failed("Created import was not locally committed")
        }
        return imported
    }

    private func requireResourceJournal(
        operationID: UUID,
        kind: YouTubePlaylistResourceOperationKind,
        state: YouTubePlaylistResourceOperationState,
        playlistID: String,
        channelID: String,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        guard let operation = try context.fetch(
            FetchDescriptor<YouTubePlaylistResourceOperation>())
            .first(where: { $0.id == operationID }),
              operation.kind == kind,
              operation.state == state,
              operation.playlistID == playlistID,
              operation.accountChannelID == channelID,
              operation.remoteObservedAt != nil,
              operation.completedAt != nil else {
            throw ValidationError.failed(
                "Resource journal did not reach a verified local commit")
        }
    }

    private func removeCreatedPlaylistIfNecessary(
        operationID: UUID,
        expectedTitle: String,
        protectedIDs: Set<String>,
        client: YouTubeDataAPIClient,
        writer: YouTubePlaylistWriteService,
        container: ModelContainer
    ) async throws {
        let context = ModelContext(container)
        let operation = try context.fetch(
            FetchDescriptor<YouTubePlaylistResourceOperation>())
            .first(where: { $0.id == operationID })
        guard let playlistID = operation?.playlistID,
              !playlistID.isEmpty,
              !protectedIDs.contains(playlistID) else { return }

        let owned = try await client.myPlaylists()
        guard let remote = owned.first(where: { $0.id == playlistID }) else { return }
        guard remote.title == expectedTitle, remote.privacy == .private else {
            throw ValidationError.failed(
                "Cleanup refused because the created ID no longer matches its exact target")
        }
        try await writer.deletePlaylist(id: playlistID)
        guard !(try await client.myPlaylists()).contains(where: { $0.id == playlistID }) else {
            throw ValidationError.failed(
                "Cleanup deletion was not confirmed by server read-back")
        }
    }
}
