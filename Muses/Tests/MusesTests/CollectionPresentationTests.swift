import Foundation
import Testing
@testable import Muses

@MainActor
@Suite("Collection presentation")
struct CollectionPresentationTests {
    @Test("Collection pages share the leading page-header rhythm")
    func collectionHeaderRhythm() {
        #expect(AppleMusicSpacing.pageHorizontal == 40)
        #expect(AppleMusicSpacing.browseTitleTop == 32)
        #expect(AppleMusicSpacing.headerToPrimary == 28)
        #expect(AppleMusicSpacing.related == 20)
        #expect(AppleMusicSpacing.section == 34)
        #expect(AppleMusicTokens.pageTitleSize == 34)
    }

    @Test("Songs canonical order is title A-Z and deterministic")
    func songsCanonicalOrder() {
        let tracks = [
            Track(title: "Zulu", artist: "B", youTubeId: "z"),
            Track(title: "Alpha", artist: "Z", youTubeId: "a2"),
            Track(title: "Alpha", artist: "A", youTubeId: "a1"),
            Track(title: "Delta", artist: "C", youTubeId: "d1")
        ]

        let rows = CollectionTrackRow.songs(from: tracks)

        #expect(rows.map(\.title) == ["Alpha", "Alpha", "Delta", "Zulu"])
        #expect(rows.map(\.artist) == ["A", "Z", "C", "B"])
        #expect(rows.map(\.canonicalIndex) == [0, 1, 2, 3])
        #expect(rows.allSatisfy { !$0.snapshot.youTubeId.isEmpty })
    }

    @Test("Legacy video-backed tracks remain ordinary Songs rows")
    func videoBackedTracksRemainSongs() {
        let video = Track(
                        title: "Wide Video",
            artist: "Artist",
            youTubeId: "video-id",
            mediaKind: .musicVideo
        )

        let rows = CollectionTrackRow.songs(from: [video])

        #expect(rows.map(\.id) == [video.id])
        #expect(video.mediaKind == .musicVideo)
    }

    @Test("Playlist rows use persisted PlaylistItem order")
    func playlistCanonicalOrder() {
        let first = Track(title: "First", artist: "A", youTubeId: "first")
        let second = Track(title: "Second", artist: "B", youTubeId: "second")
        let item0 = PlaylistItem(order: 0, track: first)
        let item1 = PlaylistItem(order: 1, track: second)

        let rows = CollectionTrackRow.playlist(from: [item1, item0])

        #expect(rows.map(\.title) == ["First", "Second"])
        #expect(rows.map(\.canonicalIndex) == [0, 1])
    }

    @Test("Visual table sorting does not rewrite canonical order")
    func visualSortPreservesCanonicalOrder() {
        let rows = [
            makeRow(title: "B", artist: "Zulu", canonicalIndex: 0),
            makeRow(title: "A", artist: "Alpha", canonicalIndex: 1)
        ]

        let visuallySorted = CollectionTrackSort.rows(
            rows,
            using: [KeyPathComparator(\.artist, comparator: .localizedStandard)]
        )

        #expect(visuallySorted.map(\.title) == ["A", "B"])
        #expect(rows.map(\.title) == ["B", "A"])
        #expect(rows.map(\.canonicalIndex) == [0, 1])
    }

    @Test("Default sorts distinguish Songs from playlists")
    func defaultSorts() {
        let songComparator = CollectionTableDefaultSort.titleAZ.comparators
        let playlistComparator = CollectionTableDefaultSort.playlistOrder.comparators
        let rows = [
            makeRow(title: "B", artist: "A", canonicalIndex: 0),
            makeRow(title: "A", artist: "B", canonicalIndex: 1)
        ]

        #expect(CollectionTrackSort.rows(rows, using: songComparator).map(\.title) == ["A", "B"])
        #expect(CollectionTrackSort.rows(rows, using: playlistComparator).map(\.title) == ["B", "A"])
    }

    @Test("Deck geometry virtualizes nine roomy cards and five compact cards")
    func responsiveDeckGeometry() {
        let roomy = CollectionDeckGeometry.resolve(containerWidth: 980, containerHeight: 760)
        let compact = CollectionDeckGeometry.resolve(containerWidth: 560, containerHeight: 760)
        let compactHeight = CollectionDeckGeometry.resolve(containerWidth: 980, containerHeight: 600)

        #expect(roomy.radius == 4)
        #expect(compact.radius == 2)
        #expect(compactHeight.radius == 2)
        #expect(CollectionDeckProjection.visibleIndices(count: 100, position: 50, radius: roomy.radius).count == 9)
        #expect(CollectionDeckProjection.visibleIndices(count: 100, position: 50, radius: compact.radius).count == 5)
        #expect(roomy.cardHeight > roomy.cardWidth)
        #expect(roomy.lowerFanClearance == 118)
        #expect(compact.lowerFanClearance == 66)
        #expect(roomy.viewportHeight > roomy.cardHeight + CollectionDeckScrubberMetrics.thumbHeight)
    }

    @Test("Deck projection clamps first and last collection boundaries")
    func deckProjectionBoundaries() {
        #expect(CollectionDeckProjection.visibleIndices(count: 0, position: 0, radius: 4).isEmpty)
        #expect(CollectionDeckProjection.visibleIndices(count: 20, position: -8, radius: 4) == [0, 1, 2, 3, 4])
        #expect(CollectionDeckProjection.visibleIndices(count: 20, position: 99, radius: 4) == [15, 16, 17, 18, 19])
    }

    @Test("Deck scrubber stays compact and maps the full collection")
    func deckScrubberGeometry() {
        #expect(CollectionDeckScrubberMetrics.width(availableWidth: 980) == 460)
        #expect(CollectionDeckScrubberMetrics.width(availableWidth: 548) == 328)
        #expect(CollectionDeckScrubberMetrics.trackHeight == 4)
        #expect(CollectionDeckScrubberMetrics.thumbWidth == 46)
        #expect(CollectionDeckScrubberMetrics.thumbHeight == 24)
        #expect(CollectionDeckScrubberMetrics.stageClearance >= CollectionDeckScrubberMetrics.thumbHeight)
        #expect(CollectionDeckScrubberMetrics.playerClearance
                > OverlayChromeMetrics.scrollBottomInset)

        let width: CGFloat = 500
        #expect(CollectionDeckScrubberMetrics.thumbCenterX(position: 0, itemCount: 20, width: width) == 23)
        #expect(CollectionDeckScrubberMetrics.thumbCenterX(position: 19, itemCount: 20, width: width) == 477)
        #expect(CollectionDeckScrubberMetrics.thumbCenterX(position: -8, itemCount: 20, width: width) == 23)
        #expect(CollectionDeckScrubberMetrics.thumbCenterX(position: 99, itemCount: 20, width: width) == 477)
        #expect(CollectionDeckScrubberMetrics.position(locationX: 23, itemCount: 20, width: width) == 0)
        #expect(CollectionDeckScrubberMetrics.position(locationX: 477, itemCount: 20, width: width) == 19)
        #expect(CollectionDeckScrubberMetrics.position(locationX: -40, itemCount: 20, width: width) == 0)
        #expect(CollectionDeckScrubberMetrics.position(locationX: 540, itemCount: 20, width: width) == 19)
        #expect(CollectionDeckScrubberMetrics.position(locationX: 250, itemCount: 1, width: width) == 0)
    }

    @Test("Primary deck activation is immediate across pointer, keyboard, and VoiceOver")
    func deckActivationSemantics() {
        #expect(CollectionDeckActivationPolicy.isPrimaryActivation(.pointer))
        #expect(CollectionDeckActivationPolicy.isPrimaryActivation(.keyboard))
        #expect(CollectionDeckActivationPolicy.isPrimaryActivation(.accessibility))
        #expect(!CollectionDeckActivationPolicy.isPrimaryActivation(.contextMenu))
    }

    @Test("Ambient-fit artwork keeps its explicit presentation policy")
    func ambientArtworkPresentation() {
        #expect(ArtworkPresentation.fitOnAmbient != ArtworkPresentation.fill)
    }

    @Test("Deck event monitor stops when a parent overlay disables browsing")
    func deckEventMonitorHonorsInheritedEnabledState() {
        #expect(CollectionDeckInputPolicy.acceptsEvents(
            stageEnabled: true,
            environmentEnabled: true
        ))
        #expect(!CollectionDeckInputPolicy.acceptsEvents(
            stageEnabled: true,
            environmentEnabled: false
        ))
        #expect(!CollectionDeckInputPolicy.acceptsEvents(
            stageEnabled: false,
            environmentEnabled: true
        ))
    }

    @Test("Velocity-aware deck snapping stays integral and bounded")
    func deckProjectedSnap() {
        let forward = CollectionDeckProjection.projectedIndex(
            startPosition: 10,
            translation: -86,
            predictedTranslation: -1_000,
            spread: 86,
            count: 20
        )
        let beforeFirst = CollectionDeckProjection.projectedIndex(
            startPosition: 1,
            translation: 500,
            predictedTranslation: 900,
            spread: 86,
            count: 20
        )
        let afterLast = CollectionDeckProjection.projectedIndex(
            startPosition: 18,
            translation: -500,
            predictedTranslation: -900,
            spread: 86,
            count: 20
        )

        #expect(forward == 17)
        #expect(beforeFirst == 0)
        #expect(afterLast == 19)
    }

    @Test("Expansion gesture is directional and rejects horizontal deck motion")
    func expansionGestureDirection() {
        #expect(CollectionDeckProjection.acceptsVerticalGesture(
            translation: CGSize(width: 8, height: -52),
            direction: .up
        ))
        #expect(CollectionDeckProjection.acceptsVerticalGesture(
            translation: CGSize(width: 4, height: 56),
            direction: .down
        ))
        #expect(!CollectionDeckProjection.acceptsVerticalGesture(
            translation: CGSize(width: 70, height: -55),
            direction: .up
        ))
        #expect(!CollectionDeckProjection.acceptsVerticalGesture(
            translation: CGSize(width: 4, height: 40),
            direction: .down
        ))
        #expect(!CollectionDeckProjection.acceptsVerticalGesture(
            translation: CGSize(width: 4, height: 56),
            direction: .up
        ))
    }

    @Test("Collection motion stays brief and honors Reduce Motion")
    func collectionMotionPolicy() {
        #expect(MusesMotion.collectionDeckSnap >= 0.12)
        #expect(MusesMotion.collectionDeckSnap <= 0.24)
        #expect(MusesMotion.collectionListTransition >= 0.26)
        #expect(MusesMotion.collectionListTransition <= 0.32)
        #expect(MusesMotion.collectionCardActivation == 0.30)
        #expect(MusesMotion.collectionDeckAnimation(reduceMotion: true) == nil)
        #expect(MusesMotion.collectionListAnimation(reduceMotion: true) == nil)
        #expect(MusesMotion.collectionCardAnimation(reduceMotion: true) == nil)
        #expect(MusesMotion.collectionDeckAnimation(reduceMotion: false) != nil)
        #expect(MusesMotion.collectionListAnimation(reduceMotion: false) != nil)
        #expect(MusesMotion.collectionCardAnimation(reduceMotion: false) != nil)
    }

    private func makeRow(title: String, artist: String, canonicalIndex: Int) -> CollectionTrackRow {
        CollectionTrackRow(
            snapshot: TrackSnapshot(
                id: UUID(),
                title: title,
                artist: artist,
                albumTitle: nil,
                durationSeconds: 120,
                                youTubeId: UUID().uuidString,
                                artworkUrl: nil,
                sampleRate: nil,
                bitDepth: nil,
                codec: nil,
                isLossless: false
            ),
            canonicalIndex: canonicalIndex
        )
    }
}
