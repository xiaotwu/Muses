import Foundation
import AppKit
import Testing
@testable import Muses

@MainActor
@Suite("Collection artwork layouts")
struct CollectionArtworkLayoutTests {
    private func row(artist: String = "Publisher", album: String? = "Liked",
                     owner: String? = "Publisher") -> CollectionTrackRow {
        CollectionTrackRow(snapshot: TrackSnapshot(
            id: UUID(), title: "Video title", artist: artist, albumTitle: album,
            durationSeconds: 180, youTubeId: "abcdefghijk", artworkUrl: nil,
            sampleRate: nil, bitDepth: nil, codec: nil, isLossless: false),
            canonicalIndex: 4, collectionOwner: owner, collectionTitle: "Liked")
    }

    @Test("Layout switch persists without losing occurrence focus or table selection")
    func presentationMemory() throws {
        let name = "MusesTests.artworkLayout.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let identity = UUID()
        let route = BrowseRoute.playlist(UUID())
        let memory = CollectionPresentationMemory(defaults: defaults)
        let entry = memory.entry(for: route)
        entry.focusedID = identity
        entry.selection = [identity]
        entry.artworkLayout = .coverWall
        entry.mode = .list
        let restored = CollectionPresentationMemory(defaults: defaults).entry(for: route)
        #expect(restored.artworkLayout == .coverWall)
        #expect(restored.focusedID == identity)
        #expect(restored.selection == [identity])
        #expect(restored.mode == .list)
        let old = Data(#"{"modeRawValue":"stage","selection":[]}"#.utf8)
        #expect(try JSONDecoder().decode(CollectionPresentationSnapshot.self, from: old).artworkLayout == .focusStrip)
    }

    @Test("Wall columns fill their available width across compact and maximized windows")
    func wallGeometry() {
        for width: CGFloat in [320, 680, 980, 1_800] {
            let wall = CollectionDeckGeometry.wall(containerWidth: width)
            #expect(wall.columns >= 1)
            let occupied = CGFloat(wall.columns) * wall.geometry.cardWidth + CGFloat(wall.columns - 1) * 24
            #expect(abs(occupied - width) < 0.01)
        }
        #expect(CollectionDeckGeometry.wall(containerWidth: 1_800).columns
                > CollectionDeckGeometry.wall(containerWidth: 680).columns)
    }

    @Test("Preview reveals only whole rows that fit above the player")
    func previewGeometry() {
        for height: CGFloat in [600, 800, 1_130, 1_600] {
            let geometry = CollectionDeckGeometry.resolve(containerWidth: 1_400, containerHeight: height)
            let count = CollectionStageSpacing.previewCount(height: height, geometry: geometry, itemCount: 500)
            #expect(count >= 0 && count <= CollectionStageSpacing.maximumPreviewRows)
            if height == 600 { #expect(count == 0) }
            if height == 1_130 { #expect(count > 0) }
            #expect(CollectionStageSpacing.previewCount(height: height, geometry: geometry, itemCount: 1) <= 1)
        }
        #expect(CollectionDeckScrubberMetrics.stageClearance >= 24)
        #expect(AppleMusicTokens.playerBottomMargin > 20)
    }

    @Test("Playlist owner and ordinary playlist title are not song artist or album")
    func songInformation() throws {
        let original = row()
        #expect(original.artist != "Publisher")
        #expect(original.album.isEmpty)
        let data = Data(#"{"id":"abcdefghijk","title":"Video title","uploader":"Publisher","track":"Song title","artist":"Performer","album":"Real album"}"#.utf8)
        let entry = try JSONDecoder().decode(YTDlpBridge.YTDlpPlaylistEntry.self, from: data)
        let information = SongDisplayInformation(row: original, metadata: entry)
        #expect(information.title == "Song title")
        #expect(information.artist == "Performer")
        #expect(information.album == "Real album")
        #expect(original.snapshot.artist == "Publisher")
        #expect(original.canonicalIndex == 4)
        let edited = row(artist: "My corrected performer", album: "My album")
        let preserved = SongDisplayInformation(row: edited, metadata: entry)
        #expect(preserved.artist == "My corrected performer")
        #expect(preserved.album == "My album")
        let unrelated = YTDlpBridge.YTDlpPlaylistEntry(id: "other_vid01", title: "Wrong", artist: "Wrong")
        #expect(SongDisplayInformation(row: original, metadata: unrelated) == SongDisplayInformation(row: original))
    }

    @Test("Missing performer falls back to the verified video publisher, even when it owns the playlist")
    func publisherFallback() {
        let original = row()
        let publisher = YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghijk", title: "Video title", uploader: "Publisher")
        #expect(SongDisplayInformation(row: original, metadata: publisher).artist == "Publisher")
        let other = YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghijk", title: "Video title", uploader: "Actual video channel", artist: "  ")
        #expect(SongDisplayInformation(row: original, metadata: other).artist == "Actual video channel")
        let blank = YTDlpBridge.YTDlpPlaylistEntry(id: "abcdefghijk", title: "Video title", uploader: "  ", artist: " ")
        #expect(SongDisplayInformation(row: original, metadata: blank).artist == original.artist)
        #expect(original.snapshot.artist == "Publisher")
        #expect(SongDisplayInformation(row: row(artist: "Unknown Artist"), metadata: other).artist == "Actual video channel")
    }

    @Test("Playlist API credits the video publisher rather than the playlist account")
    func videoPublisherIdentity() throws {
        let raw = Data(#"{"id":"item1","snippet":{"title":"Song","channelTitle":"My account","videoOwnerChannelTitle":"Video publisher"},"contentDetails":{"videoId":"abcdefghijk"}}"#.utf8)
        let item = try JSONDecoder().decode(YouTubePlaylistItem.self, from: raw)
        #expect(item.channelTitle == "Video publisher")
        let roundTrip = try JSONDecoder().decode(YouTubePlaylistItem.self, from: JSONEncoder().encode(item))
        #expect(roundTrip.channelTitle == "Video publisher")
        let missing = Data(#"{"snippet":{"title":"Song","channelTitle":"My account"},"contentDetails":{"videoId":"abcdefghijk"}}"#.utf8)
        #expect(try JSONDecoder().decode(YouTubePlaylistItem.self, from: missing).channelTitle.isEmpty)
    }

    @Test("Publisher channel is used when yt-dlp omits its uploader alias")
    func channelPublisherFallback() throws {
        let raw = Data(#"{"id":"abcdefghijk","title":"Video title","uploader":"  ","channel":"Video publisher"}"#.utf8)
        let entry = try JSONDecoder().decode(YTDlpBridge.YTDlpPlaylistEntry.self, from: raw)
        #expect(entry.uploader == "Video publisher")
        #expect(SongDisplayInformation(row: row(), metadata: entry).artist == "Video publisher")
    }

    @Test("Online sibling queue preserves performer and album credits")
    func siblingCredits() {
        let playing = row().snapshot
        let entries = [YTDlpBridge.YTDlpPlaylistEntry(id: playing.youTubeId, title: playing.title),
                       YTDlpBridge.YTDlpPlaylistEntry(id: "bcdefghijkl", title: "Video title", uploader: "Channel", track: "Song", album: "Album", artist: "Singer")]
        let context = TrackSnapshot.playbackContext(playing: playing, youTubeEntries: entries)
        #expect(context[0].id == playing.id)
        #expect(context[1].title == "Song")
        #expect(context[1].artist == "Singer")
        #expect(context[1].albumTitle == "Album")
    }

    @Test("Light glass keeps artwork hues and falls back for grayscale covers")
    func lightArtworkPalette() {
        let purple = NSColor(srgbRed: 0.52, green: 0.24, blue: 0.72, alpha: 1)
        let palette = ArtworkAtmospherePalette.lightColors(from: [.white, .darkGray, purple])
        #expect(palette.count == 1)
        #expect(palette.first == purple)
        #expect(!ArtworkAtmospherePalette.lightColors(from: [.white, .gray]).isEmpty)
    }

    @Test("Now Playing grows at maximized size and centers when lyrics are hidden")
    func artworkGeometry() {
        let window = NowPlayingLayout.resolve(width: 1_228, height: 768, isPlaying: true)
        let maximum = NowPlayingLayout.resolve(width: 1_912, height: 1_160, isPlaying: true)
        let centered = NowPlayingLayout.resolve(width: 1_912, height: 1_160, isPlaying: true, showsLyrics: false)
        #expect(maximum.stageSide > window.stageSide)
        #expect(maximum.stageSide + 270 <= 1_160)
        #expect(centered.presentation == .centered)
        #expect(centered.stageSide == maximum.stageSide)
        #expect(abs(centered.renderedArtworkSide - centered.stageSide) < 0.01)
    }
}
