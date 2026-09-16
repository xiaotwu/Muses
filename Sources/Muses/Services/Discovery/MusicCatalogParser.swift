import Foundation

/// Parses display contents only; menus, overlays and tracking payloads are never traversed.
enum MusicCatalogParser {
    typealias Object = [String: Any]

    static func page(_ data: Data, session: UUID, endpoint: String, region: String) throws -> MusicCatalogPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? Object,
              root["error"] == nil else { throw MusicCatalogError.invalidResponse }
        var rows: [MusicCatalogItem] = []
        var related: [MusicCatalogItem] = []
        var inRelatedSection = false
        func append(_ item: MusicCatalogItem) {
            if inRelatedSection { related.append(item) } else { rows.append(item) }
        }
        var filters: [MusicCatalogFilter] = []
        var continuation: String?
        var recognized = false
        func visit(_ value: Any) {
            if let list = value as? [Any] { list.forEach(visit); return }
            guard let object = value as? Object else { return }
            if let episode = object["musicMultiRowListItemRenderer"] as? Object,
               let title = episode["title"] as? Object,
               let endpoint = episode["onTap"] as? Object {
                let adapted: Object = ["navigationEndpoint": endpoint, "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": title]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": episode["subtitle"] ?? [:]]]
                ], "thumbnail": episode["thumbnail"] ?? [:]]
                recognized = true
                if let item = item(adapted) { append(item) }
                return
            }
            if let carousel = object["musicCarouselShelfRenderer"] as? Object {
                let previous = inRelatedSection
                inRelatedSection = true
                recognized = true
                if let contents = carousel["contents"] { visit(contents) }
                inRelatedSection = previous
                return
            }
            if let tile = object["musicTwoRowItemRenderer"] as? Object,
               let title = tile["title"] as? Object {
                var adapted: Object = ["flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": title]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": tile["subtitle"] ?? [:]]]
                ], "thumbnail": tile["thumbnailRenderer"] ?? [:]]
                if let endpoint = tile["navigationEndpoint"] { adapted["navigationEndpoint"] = endpoint }
                recognized = true
                if let item = item(adapted) { append(item) }
                return
            }
            if let row = object["musicResponsiveListItemRenderer"] as? Object {
                recognized = true
                if let item = item(row) { append(item) }
                return
            }
            if let card = object["musicCardShelfRenderer"] as? Object,
               let title = card["title"] as? Object {
                let adapted: Object = ["flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": title]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": card["subtitle"] ?? [:]]]
                ], "thumbnail": card["thumbnail"] ?? [:]]
                if let item = item(adapted) { append(item) }
            }
            if let panel = object["playlistPanelVideoRenderer"] as? Object,
               let title = panel["title"] as? Object,
               let endpoint = panel["navigationEndpoint"] as? Object {
                let adapted: Object = ["navigationEndpoint": endpoint, "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": title]],
                    ["musicResponsiveListItemFlexColumnRenderer": ["text": panel["longBylineText"] ?? [:]]]
                ], "thumbnail": ["musicThumbnailRenderer": ["thumbnail": panel["thumbnail"] ?? [:]]]]
                recognized = true
                if let item = item(adapted) { append(item) }
                return
            }
            if let chip = object["chipCloudChipRenderer"] as? Object,
               let endpoint = chip["navigationEndpoint"] as? Object,
               let search = endpoint["searchEndpoint"] as? Object,
               let params = search["params"] as? String,
               let kind = filterKind(text(chip["text"])) {
                filters.append(.init(kind: kind, params: params))
                return
            }
            if let next = object["nextContinuationData"] as? Object,
               let token = next["continuation"] as? String { continuation = token; return }
            if let next = object["continuationCommand"] as? Object,
               let token = next["token"] as? String { continuation = token; return }
            // These paths preserve source array order. No recursive dictionary walk:
            // menu artist/album links must never become additional search rows.
            let containers = ["tabbedSearchResultsRenderer", "tabRenderer", "sectionListRenderer",
                              "musicShelfRenderer", "musicCardShelfRenderer", "itemSectionRenderer",
                              "musicShelfContinuation", "musicPlaylistShelfContinuation", "musicPlaylistShelfRenderer",
                              "twoColumnBrowseResultsRenderer", "singleColumnBrowseResultsRenderer",
                              "sectionListContinuation", "continuationItemRenderer", "chipCloudRenderer",
                              "singleColumnMusicWatchNextResultsRenderer", "watchNextTabbedResultsRenderer",
                              "musicQueueRenderer", "playlistPanelRenderer"]
            for key in containers {
                if let child = object[key] { recognized = true; visit(child) }
            }
            for key in ["tabs", "tabbedRenderer", "content", "contents", "secondaryContents", "header", "chips", "continuations", "continuationEndpoint"] {
                if let child = object[key] { visit(child) }
            }
        }
        if let contents = root["contents"] { visit(contents) }
        if let contents = root["continuationContents"] { visit(contents) }
        for action in (root["onResponseReceivedActions"] as? [Object] ?? []) {
            if let append = action["appendContinuationItemsAction"] as? Object,
               let items = append["continuationItems"] { recognized = true; visit(items) }
        }
        guard recognized else { throw MusicCatalogError.invalidResponse }
        // Search deduplication is by actual source identity; browse preserves duplicate occurrences.
        var seen = Set<String>()
        if endpoint == "search" { rows = rows.filter { seen.insert($0.id).inserted } }
        var seenRelated = Set<String>()
        related = related.filter { seenRelated.insert($0.id).inserted }
        return .init(items: rows, filters: filters,
                     next: continuation.map { .init(session: session, endpoint: endpoint, token: $0) },
                     fetchedAt: Date(), region: region, relatedItems: related)
    }

    private static func item(_ row: Object) -> MusicCatalogItem? {
        let columns = (row["flexColumns"] as? [Object] ?? []).compactMap { $0["musicResponsiveListItemFlexColumnRenderer"] as? Object }
        guard let first = columns.first, let titleObject = first["text"] as? Object else { return nil }
        let title = text(titleObject)
        guard !title.isEmpty else { return nil }
        let titleRuns = titleObject["runs"] as? [Object] ?? []
        let primary = (row["navigationEndpoint"] as? Object) ?? titleRuns.first?["navigationEndpoint"] as? Object
        guard let primary, let identity = identity(primary) else { return nil }
        var artists: [MusicCatalogLink] = [], releases: [MusicCatalogLink] = []
        var channels: [MusicCatalogChannel] = []
        for column in columns.dropFirst() {
            let runs = (column["text"] as? Object)?["runs"] as? [Object] ?? []
            for run in runs {
                guard let endpoint = run["navigationEndpoint"] as? Object,
                      let name = run["text"] as? String else { continue }
                if let link = Self.identity(endpoint) {
                    let value = MusicCatalogLink(id: link.0, title: name, kind: link.1)
                    if link.1 == .artist && !artists.contains(value) { artists.append(value) }
                    if link.1 == .album && !releases.contains(value) { releases.append(value) }
                } else if let browse = endpoint["browseEndpoint"] as? Object,
                          let id = browse["browseId"] as? String, id.hasPrefix("UC"), validID(id) {
                    let value = MusicCatalogChannel(id: "browse:" + id, title: name)
                    if !channels.contains(value) { channels.append(value) }
                }
            }
        }
        let thumbnail = (row["thumbnail"] as? Object)?["musicThumbnailRenderer"] as? Object
        let thumbs = (thumbnail?["thumbnail"] as? Object)?["thumbnails"] as? [Object] ?? []
        let artwork = (thumbs.last?["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return .init(id: identity.0, kind: identity.1, title: title,
                     subtitle: columns.dropFirst().map { text($0["text"]) }.filter { !$0.isEmpty }.joined(separator: " · "),
                     artwork: artwork, artists: artists, releases: releases, channels: channels)
    }

    private static func identity(_ endpoint: Object) -> (String, MusicCatalogKind)? {
        if let watch = endpoint["watchEndpoint"] as? Object,
           let id = watch["videoId"] as? String, id.count == 11, validID(id),
           let configs = watch["watchEndpointMusicSupportedConfigs"] as? Object,
           let config = configs["watchEndpointMusicConfig"] as? Object,
           let type = config["musicVideoType"] as? String {
            let kind: MusicCatalogKind
            switch type {
            case "MUSIC_VIDEO_TYPE_ATV": kind = .song
            case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC": kind = .video
            case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": kind = .episode
            default: return nil
            }
            return ("video:" + id, kind)
        }
        guard let browse = endpoint["browseEndpoint"] as? Object,
              let id = browse["browseId"] as? String, validID(id),
              let configs = browse["browseEndpointContextSupportedConfigs"] as? Object,
              let config = configs["browseEndpointContextMusicConfig"] as? Object,
              let type = config["pageType"] as? String else { return nil }
        let kind: MusicCatalogKind
        switch type {
        case "MUSIC_PAGE_TYPE_ALBUM": kind = .album
        case "MUSIC_PAGE_TYPE_ARTIST": kind = .artist
        case "MUSIC_PAGE_TYPE_PLAYLIST": kind = .playlist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW", "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": kind = .podcast
        default: return nil
        }
        return ("browse:" + id, kind)
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func text(_ value: Any?) -> String {
        guard let object = value as? Object else { return "" }
        return object["simpleText"] as? String ?? (object["runs"] as? [Object] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    // The public session pins hl=en. Only source-provided chip params are sent;
    // no fabricated filter tokens and no inferred row types from labels.
    private static func filterKind(_ value: String) -> MusicCatalogKind? {
        switch value {
        case "Songs": .song
        case "Videos": .video
        case "Albums": .album
        case "Artists": .artist
        case "Community playlists", "Playlists": .playlist
        case "Podcasts": .podcast
        case "Episodes": .episode
        default: nil
        }
    }
}
