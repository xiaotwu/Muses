import Foundation

/// A release item discovered online from YouTube Music / YouTube Channel.
struct OnlineReleaseItem: Identifiable, Sendable, Equatable {
    var id: String { playlistID }
    let playlistID: String
    let title: String
    let artworkURL: String?
    let year: Int?
    let kind: CatalogReleaseKind
    let channelID: String?

    init(
        playlistID: String,
        title: String,
        artworkURL: String? = nil,
        year: Int? = nil,
        kind: CatalogReleaseKind = .album,
        channelID: String? = nil
    ) {
        self.playlistID = playlistID
        self.title = title
        self.artworkURL = artworkURL
        self.year = year
        self.kind = kind
        self.channelID = channelID
    }

    var stableID: String {
        "playlist:\(playlistID)"
    }
}

/// Discovered online discography and popular tracks for an artist.
struct ArtistOnlineDiscography: Sendable, Equatable {
    let artistName: String
    let channelID: String?
    let topTracks: [YTDlpBridge.YTDlpPlaylistEntry]
    let albums: [OnlineReleaseItem]
    let singlesAndEPs: [OnlineReleaseItem]

    init(
        artistName: String,
        channelID: String? = nil,
        topTracks: [YTDlpBridge.YTDlpPlaylistEntry] = [],
        albums: [OnlineReleaseItem] = [],
        singlesAndEPs: [OnlineReleaseItem] = []
    ) {
        self.artistName = artistName
        self.channelID = channelID
        self.topTracks = topTracks
        self.albums = albums
        self.singlesAndEPs = singlesAndEPs
    }

    var isEmpty: Bool {
        topTracks.isEmpty && albums.isEmpty && singlesAndEPs.isEmpty
    }
}
