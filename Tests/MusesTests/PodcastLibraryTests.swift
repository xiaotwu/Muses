import Foundation
import SwiftData
import Testing
@testable import Muses

@Suite("Podcast library", .serialized)
@MainActor
struct PodcastLibraryTests {
    @Test("follow requires a stable podcast browse identity and remains local")
    func followIdentity() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = PodcastLibraryService(modelContainer: container)
        let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")

        try service.follow(show, now: Date(timeIntervalSince1970: 10))
        #expect(service.isFollowing(catalogID: show.id))

        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<PodcastShow>())
        #expect(rows.count == 1)
        #expect(rows[0].catalogID == show.id)

        try service.unfollow(catalogID: show.id)
        #expect(!service.isFollowing(catalogID: show.id))
        #expect(try ctx.fetch(FetchDescriptor<PodcastEpisodeState>()).isEmpty)

        #expect(throws: PodcastLibraryError.invalidShowIdentity) {
            try service.follow(item(id: "video:abcdefghijk", kind: .podcast, title: "Bad"))
        }
    }

    @Test("episode ingest preserves progress and rejects non-video identities")
    func ingestPreservesTruth() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = PodcastLibraryService(modelContainer: container)
        let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")
        let episode = item(id: "video:abcdefghijk", kind: .episode, title: "One")
        try service.ingest(show: show, episodes: [episode])
        try service.updateProgress(videoID: "abcdefghijk", positionMs: 12_000,
                                   durationMs: 120_000)

        let renamed = item(id: episode.id, kind: .episode, title: "One (updated)")
        try service.ingest(show: show, episodes: [renamed])
        let snapshot = try #require(service.episodes(showCatalogID: show.id).first)
        #expect(snapshot.title == "One (updated)")
        #expect(snapshot.lastPositionMs == 12_000)
        #expect(!snapshot.completed)

        let date = Date(timeIntervalSince1970: 100)
        try service.enrich([.init(videoID: "abcdefghijk", channelID: nil, publishedAt: date,
                                  durationMs: 180_000, availability: .unavailable)])
        let enriched = try #require(service.episode(videoID: "abcdefghijk"))
        #expect(enriched.publishedAt == date)
        #expect(enriched.durationMs == 180_000)
        #expect(enriched.availability == .unavailable)
        #expect(enriched.lastPositionMs == 12_000)

        #expect(throws: PodcastLibraryError.invalidEpisodeIdentity) {
            try service.ingest(show: show, episodes: [
                item(id: "browse:not-an-episode", kind: .episode, title: "Bad")
            ])
        }
    }

    @Test("one episode keeps shared progress in every source-backed show")
    func crossShowMembership() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = PodcastLibraryService(modelContainer: container)
        let first = item(id: "browse:MPSPfirst", kind: .podcast, title: "First")
        let second = item(id: "browse:MPSPsecond", kind: .podcast, title: "Second")
        let episode = item(id: "video:abcdefghijk", kind: .episode, title: "Shared")
        try service.follow(first, now: Date(timeIntervalSince1970: 10))
        try service.follow(second, now: Date(timeIntervalSince1970: 20))
        try service.ingest(show: first, episodes: [episode])
        try service.updateProgress(videoID: "abcdefghijk", positionMs: 12_000,
                                   durationMs: 120_000)
        try service.ingest(show: second, episodes: [episode])

        #expect(service.followedShows().map(\.catalogID) == [second.id, first.id])
        #expect(service.episodes(showCatalogID: first.id).first?.lastPositionMs == 12_000)
        #expect(service.episodes(showCatalogID: second.id).first?.lastPositionMs == 12_000)
        #expect(service.episodes(showCatalogID: first.id).first?.showCatalogID == first.id)
        #expect(service.episodes(showCatalogID: second.id).first?.showCatalogID == second.id)
        try service.unfollow(catalogID: first.id)
        #expect(service.episodes(showCatalogID: first.id).count == 1)
        #expect(service.episodes(showCatalogID: second.id).count == 1)
    }

    @Test("completion uses 90 percent or final minute and can be reset")
    func completionPolicy() throws {
        #expect(PodcastLibraryService.isComplete(positionMs: 540_000, durationMs: 600_000))
        #expect(PodcastLibraryService.isComplete(positionMs: 250_000, durationMs: 300_000))
        #expect(!PodcastLibraryService.isComplete(positionMs: 200_000, durationMs: 300_000))
        #expect(!PodcastLibraryService.isComplete(positionMs: 10_000, durationMs: 0))
        #expect(!PodcastLibraryService.isComplete(positionMs: 0, durationMs: 30_000))
        #expect(!PodcastLibraryService.isComplete(positionMs: 15_000, durationMs: 30_000))
        #expect(PodcastLibraryService.isComplete(positionMs: 27_000, durationMs: 30_000))

        let container = try makeModelContainer(inMemory: true)
        let service = PodcastLibraryService(modelContainer: container)
        let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")
        try service.ingest(show: show, episodes: [
            item(id: "video:abcdefghijk", kind: .episode, title: "One")
        ])
        try service.updateProgress(videoID: "abcdefghijk", positionMs: 245_000,
                                   durationMs: 300_000,
                                   now: Date(timeIntervalSince1970: 20))
        #expect(service.episodes(showCatalogID: show.id).first?.completed == true)

        try service.markUnplayed(videoID: "abcdefghijk")
        let reset = try #require(service.episodes(showCatalogID: show.id).first)
        #expect(!reset.completed)
        #expect(reset.lastPositionMs == 0)
    }

    @Test("publication-order queue refuses to invent missing dates")
    func publicationOrder() throws {
        let container = try makeModelContainer(inMemory: true)
        let service = PodcastLibraryService(modelContainer: container)
        let showID = "browse:MPSPshow"
        let ctx = ModelContext(container)
        ctx.insert(PodcastEpisodeState(videoID: "abcdefghij1", showCatalogID: showID,
                                       title: "New", publishedAt: Date(timeIntervalSince1970: 20)))
        ctx.insert(PodcastEpisodeState(videoID: "abcdefghij2", showCatalogID: showID,
                                       title: "Old", publishedAt: Date(timeIntervalSince1970: 10)))
        try ctx.save()

        #expect(try service.unplayedByPublicationDate(showCatalogID: showID).map(\.videoID)
            == ["abcdefghij2", "abcdefghij1"])
        let dated = service.unplayedQueue(showCatalogID: showID,
            sourceVideoIDs: ["abcdefghij1", "abcdefghij2"])
        #expect(dated.order == .publicationDate)
        #expect(dated.videoIDs == ["abcdefghij2", "abcdefghij1"])

        ctx.insert(PodcastEpisodeState(videoID: "abcdefghij3", showCatalogID: showID,
                                       title: "Unknown date"))
        try ctx.save()
        #expect(throws: PodcastLibraryError.missingPublicationDate) {
            _ = try service.unplayedByPublicationDate(showCatalogID: showID)
        }
        let fallback = service.unplayedQueue(showCatalogID: showID,
            sourceVideoIDs: ["abcdefghij3", "abcdefghij1", "abcdefghij2"])
        #expect(fallback.order == .sourceOrder)
        #expect(fallback.videoIDs == ["abcdefghij3", "abcdefghij1", "abcdefghij2"])
    }

    @Test("episode tracks keep podcast media kind through snapshots and old queues decode")
    func mediaKindRoundTrip() async throws {
        let track = Track(title: "Episode", artist: "Show", durationMs: 1_000,
                          youTubeId: "abcdefghijk", mediaKind: .podcastEpisode)
        let snapshot = TrackSnapshot(from: track)
        #expect(snapshot.mediaKind == .podcastEpisode)
        let decoded = try JSONDecoder().decode(TrackSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        #expect(decoded.mediaKind == .podcastEpisode)

        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Old","artist":"A","durationSeconds":1,"youTubeId":"abcdefghijk","isLossless":false,"liked":false}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TrackSnapshot.self, from: legacy).mediaKind == .song)

        let container = try makeModelContainer(inMemory: true)
        let search = YouTubeSearchService(
            bridge: MockImportBridge(), modelContainer: container)
        let resolved = try await search.resolveTrack(
            entry: .init(id: "abcdefghijk", title: "Episode"),
            mediaKindOverride: .podcastEpisode)
        #expect(resolved.mediaKind == .podcastEpisode)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Track>()).first?.mediaKind
            == .podcastEpisode)
    }

    @Test("playback events checkpoint and complete only podcast episodes")
    func playbackEvents() throws {
        let container = try makeModelContainer(inMemory: true)
        let bus = PlaybackEventBus()
        let service = PodcastLibraryService(modelContainer: container, eventBus: bus)
        let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")
        try service.ingest(show: show, episodes: [
            item(id: "video:abcdefghijk", kind: .episode, title: "One")
        ])
        let track = TrackSnapshot(
            id: UUID(), title: "One", artist: "Show", albumTitle: nil,
            durationSeconds: 300, youTubeId: "abcdefghijk", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false,
            mediaKind: .podcastEpisode)

        bus.post(.trackStarted(track))
        bus.post(.trackSeeked(trackId: track.id, toMs: 45_000))
        #expect(service.episode(videoID: "abcdefghijk")?.lastPositionMs == 45_000)
        bus.post(.trackCompleted(track, listenedMs: 250_000))
        #expect(service.episode(videoID: "abcdefghijk")?.completed == true)
    }

    @Test("podcast selection resumes through the shared playback service")
    func sharedPlaybackResume() async throws {
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(engine: engine, queue: queue)
        let track = TrackSnapshot(
            id: UUID(), title: "Episode", artist: "Show", albumTitle: nil,
            durationSeconds: 300, youTubeId: "abcdefghijk", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false,
            mediaKind: .podcastEpisode)
        let entries = [
            YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghijk", title: "Episode"),
            YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghij2", title: "Next")
        ]
        let context = TrackSnapshot.playbackContext(
            playing: track, youTubeEntries: entries,
            mediaKind: .podcastEpisode)

        playback.playTrack(track, context: context, from: .podcast,
                           resumeAtMs: 45_000)
        try await Task.sleep(for: .milliseconds(20))

        #expect(queue.current()?.fromContext == .podcast)
        #expect(queue.items.allSatisfy { $0.track.mediaKind == .podcastEpisode })
        #expect(engine.lastLoadedTrack?.id == track.id)
        #expect(engine.lastSeekTime == 45)
        playback.setPodcastPlaybackRate(1.5)
        #expect(playback.podcastPlaybackRate == 1.5)
        #expect(engine.playbackRates.last == 1.5)
        playback.skipPodcast(by: 15)
        #expect(engine.lastSeekTime == 60)
        playback.skipPodcast(by: -100)
        #expect(engine.lastSeekTime == 0)

        let music = TrackSnapshot(
            id: UUID(), title: "Song", artist: "Artist", albumTitle: nil,
            durationSeconds: 180, youTubeId: "abcdefghij3", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false)
        playback.playTrack(music, context: [music], from: .search)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.playbackRates.last == 1)
        let seeks = engine.seekCallCount
        playback.skipPodcast(by: 15)
        #expect(engine.seekCallCount == seeks)
    }

    @Test("pause checkpoints podcast progress when listening statistics are disabled")
    func pauseCheckpoint() async throws {
        let container = try makeModelContainer(inMemory: true)
        let engine = RecordingEngine()
        let queue = QueueService()
        let playback = PlaybackService(engine: engine, queue: queue)
        let service = PodcastLibraryService(modelContainer: container, eventBus: playback.eventBus)
        let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")
        try service.ingest(show: show, episodes: [item(id: "video:abcdefghijk", kind: .episode, title: "One")])
        let session = SessionService(modelContainer: container, eventBus: playback.eventBus,
            playback: playback, queue: queue, podcastCheckpoint: { track, position, duration in
                service.checkpoint(track: track, positionMs: position, durationSeconds: duration)
            }, enabledProvider: { false })
        let track = TrackSnapshot(from: Track(title: "One", artist: "Show",
            durationMs: 300_000, youTubeId: "abcdefghijk", mediaKind: .podcastEpisode))
        playback.playTrack(track, context: [track], from: .podcast)
        for _ in 0..<100 where engine.lastLoadedTrack == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        engine.state.position = 42
        playback.pause()
        #expect(service.episode(videoID: "abcdefghijk")?.lastPositionMs == 42_000)
        #expect(!service.persistenceFailed)
        withExtendedLifetime(session) {}
    }

    @Test("unknown-duration natural completion still records played state")
    func unknownDurationCompletion() throws {
        let container = try makeModelContainer(inMemory: true)
        let bus = PlaybackEventBus()
        let service = PodcastLibraryService(modelContainer: container, eventBus: bus)
        try service.ingest(show: item(id: "browse:MPSPshow", kind: .podcast, title: "Show"),
            episodes: [item(id: "video:abcdefghijk", kind: .episode, title: "One")])
        let track = TrackSnapshot(from: Track(title: "One", artist: "Show",
            youTubeId: "abcdefghijk", mediaKind: .podcastEpisode))
        bus.post(.trackCompleted(track, listenedMs: 0))
        #expect(service.episode(videoID: "abcdefghijk")?.completed == true)
    }

    @Test("podcasts do not count toward Smart Shuffle recommendation intervals")
    func noMusicInsertion() {
        let queue = QueueService()
        let tracks = (0..<5).map { index in
            TrackSnapshot(from: Track(title: "Episode \(index)", artist: "Show",
                youTubeId: "abcdefghij\(index)", mediaKind: .podcastEpisode))
        }
        queue.setSmartShuffle(true)
        queue.play(tracks[0], context: tracks, from: .podcast)
        for track in tracks {
            #expect(queue.current()?.track.id == track.id)
            #expect(!queue.needsRecommendation)
            _ = queue.next()
        }
        #expect(queue.smartShuffle.collectionPlayed == 0)
    }

    @Test("generation four upgrade preserves existing tracks and podcast state survives reopening")
    func diskUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "podcast-upgrade.sqlite")
        let trackID = UUID()
        try autoreleasepool {
            let priorModels = MusesSchema.models.filter {
                $0 != PodcastShow.self && $0 != PodcastEpisodeState.self
                    && $0 != PodcastEpisodeMembership.self
            }
            let prior = try ModelContainer(for: Schema(priorModels, version: .init(4, 0, 0)),
                configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(prior)
            ctx.insert(Track(id: trackID, title: "Preserved", artist: "Artist",
                youTubeId: "abcdefghijk", playCount: 7, liked: true))
            try ctx.save()
        }
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: url)
            let service = PodcastLibraryService(modelContainer: container)
            let show = item(id: "browse:MPSPshow", kind: .podcast, title: "Show")
            try service.follow(show)
            try service.ingest(show: show, episodes: [item(id: "video:abcdefghij2", kind: .episode, title: "Two")])
            try service.updateProgress(videoID: "abcdefghij2", positionMs: 42_000, durationMs: 300_000)
        }
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: url)
            let ctx = ModelContext(container)
            let track = try #require(ctx.fetch(FetchDescriptor<Track>()).first)
            #expect(track.id == trackID && track.liked && track.playCount == 7)
            let service = PodcastLibraryService(modelContainer: container)
            #expect(service.isFollowing(catalogID: "browse:MPSPshow"))
            #expect(service.episode(videoID: "abcdefghij2")?.lastPositionMs == 42_000)
            try service.unfollow(catalogID: "browse:MPSPshow")
            #expect(service.episode(videoID: "abcdefghij2")?.lastPositionMs == 42_000)
        }
    }

    @Test("isolated production copy opens at current schema and survives cold reopen",
          .enabled(if: ProcessInfo.processInfo.environment[
            "MUSES_TEST_PODCAST_STORE_COPY"] != nil))
    func productionCopyUpgrade() throws {
        let path = try #require(ProcessInfo.processInfo.environment[
            "MUSES_TEST_PODCAST_STORE_COPY"])
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        #expect(url.path.hasPrefix(temporary + "/"))
        #expect(url.path != musesDefaultStoreURL().path)
        var trackIDs: Set<UUID> = []
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: url)
            let ctx = ModelContext(container)
            trackIDs = Set(try ctx.fetch(FetchDescriptor<Track>()).map(\.id))
            _ = try ctx.fetch(FetchDescriptor<PodcastShow>())
            _ = try ctx.fetch(FetchDescriptor<PodcastEpisodeState>())
            _ = try ctx.fetch(FetchDescriptor<PodcastEpisodeMembership>())
        }
        try autoreleasepool {
            let container = try makeModelContainer(storeURL: url)
            let reopenedIDs = Set(try ModelContext(container)
                .fetch(FetchDescriptor<Track>()).map(\.id))
            #expect(reopenedIDs == trackIDs)
        }
    }

    private func item(id: String, kind: MusicCatalogKind,
                      title: String) -> MusicCatalogItem {
        .init(id: id, kind: kind, title: title, subtitle: "",
              artwork: URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"),
              artists: [], releases: [], channels: [])
    }
}
