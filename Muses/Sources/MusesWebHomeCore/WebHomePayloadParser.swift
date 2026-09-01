import Foundation
import CryptoKit
import MusesWebHomeProtocol

struct WebHomePayloadParser: Sendable {
    private static let maximumPayloadBytes = 10 * 1024 * 1024
    private static let supportedContainers: Set<String> = [
        "musicCarouselShelfRenderer",
        "musicShelfRenderer",
        "gridRenderer",
        "musicPlaylistShelfRenderer",
        "musicShelfContinuation"
    ]
    private static let supportedItems: Set<String> = [
        "musicTwoRowItemRenderer",
        "musicResponsiveListItemRenderer",
        "musicMultiRowListItemRenderer"
    ]
    private static let traversalRenderers: Set<String> = [
        "singleColumnBrowseResultsRenderer",
        "tabRenderer",
        "sectionListRenderer"
    ]

    func parse(_ data: Data) throws -> [WebHomeSection] {
        guard !data.isEmpty, data.count <= Self.maximumPayloadBytes,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw WebHomeCoreError.code(.shapeChanged)
        }

        var audit = ParseAudit()
        var sections: [WebHomeSection] = []
        visit(root, audit: &audit, sections: &sections)

        guard audit.recognizedContainers > 0,
              !sections.isEmpty,
              audit.invalidContainers * 2 <= audit.recognizedContainers,
              audit.recognizedItems > 0,
              audit.invalidItems * 2 <= audit.recognizedItems else {
            throw WebHomeCoreError.code(.shapeChanged)
        }

        var seen = Set<String>()
        let unique = sections.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { throw WebHomeCoreError.code(.shapeChanged) }
        return unique
    }

    private func visit(
        _ value: Any,
        audit: inout ParseAudit,
        sections: inout [WebHomeSection]
    ) {
        if let dictionary = value as? [String: Any] {
            var consumed = Set<String>()
            for key in Self.supportedContainers {
                guard let renderer = dictionary[key] as? [String: Any] else { continue }
                consumed.insert(key)
                audit.recognizedContainers += 1
                if let section = parseContainer(key: key, renderer: renderer, audit: &audit) {
                    sections.append(section)
                } else {
                    audit.invalidContainers += 1
                }
            }
            for (key, child) in dictionary where !consumed.contains(key) {
                if key.hasSuffix("Renderer"), !Self.traversalRenderers.contains(key) {
                    continue
                }
                visit(child, audit: &audit, sections: &sections)
            }
        } else if let array = value as? [Any] {
            for child in array { visit(child, audit: &audit, sections: &sections) }
        }
    }

    private func parseContainer(
        key: String,
        renderer: [String: Any],
        audit: inout ParseAudit
    ) -> WebHomeSection? {
        let candidates = itemCandidates(in: renderer)
        var items: [WebHomeItem] = []
        var seenItems = Set<WebHomeEndpoint>()
        var usedResponsiveRenderer = false

        for candidate in candidates {
            guard let pair = candidate.first(where: { Self.supportedItems.contains($0.key) }),
                  let itemRenderer = pair.value as? [String: Any] else {
                continue // Unknown renderers are intentionally ignored.
            }
            audit.recognizedItems += 1
            usedResponsiveRenderer = usedResponsiveRenderer
                || pair.key == "musicResponsiveListItemRenderer"
            guard let item = parseItem(itemRenderer, rendererKey: pair.key) else {
                audit.invalidItems += 1
                continue
            }
            if seenItems.insert(item.identity).inserted { items.append(item) }
        }
        guard !items.isEmpty else { return nil }

        let header = headerDictionary(in: renderer)
        let title = textValue(header?["title"])
            ?? textValue(renderer["title"])
            ?? (key == "musicShelfContinuation" ? "More" : nil)
        guard let title, !title.isEmpty else { return nil }
        let subtitle = textValue(header?["strapline"])
            ?? textValue(header?["subtitle"])
            ?? textValue(renderer["subtitle"])
        let browseEndpoint = endpoint(in: header ?? renderer, preferred: .browse)
        let playEndpoint = endpoint(in: header ?? renderer, preferred: .play)
        let sourceEndpoint = browseEndpoint
            ?? playEndpoint
            ?? items.first?.browseEndpoint
            ?? items.first?.playEndpoint
            ?? items.first?.identity
        guard let sourceEndpoint else { return nil }
        let sectionID = stableSectionID(
            rendererKey: key,
            sourceEndpoint: sourceEndpoint)

        return WebHomeSection(
            id: sectionID,
            title: title,
            subtitle: subtitle,
            layout: layout(
                for: key,
                usesResponsiveRenderer: usedResponsiveRenderer),
            browseEndpoint: browseEndpoint,
            playEndpoint: playEndpoint,
            items: items,
            continuationToken: continuationToken(in: renderer))
    }

    private func parseItem(
        _ renderer: [String: Any],
        rendererKey: String
    ) -> WebHomeItem? {
        let columns = (renderer["flexColumns"] as? [Any])?.compactMap { value -> [String: Any]? in
            guard let wrapper = value as? [String: Any] else { return nil }
            return wrapper["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        } ?? []
        let title = textValue(renderer["title"])
            ?? columns.first.flatMap { textValue($0["text"]) }
        guard let title, !title.isEmpty else { return nil }
        let subtitle = textValue(renderer["subtitle"])
            ?? columns.dropFirst().compactMap { textValue($0["text"]) }.first

        let playEndpoint = endpoint(in: renderer, preferred: .play)
        let browseEndpoint = endpoint(in: renderer, preferred: .browse)
        guard let identity = playEndpoint ?? browseEndpoint else { return nil }

        return WebHomeItem(
            identity: identity,
            title: title,
            subtitle: subtitle,
            browseEndpoint: browseEndpoint,
            playEndpoint: playEndpoint,
            artworkURLs: artworkURLs(in: renderer),
            availability: availability(in: renderer))
    }

    private func itemCandidates(in renderer: [String: Any]) -> [[String: Any]] {
        for key in ["contents", "items"] {
            if let array = renderer[key] as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    private func headerDictionary(in renderer: [String: Any]) -> [String: Any]? {
        guard let header = renderer["header"] as? [String: Any] else { return nil }
        for key in [
            "musicCarouselShelfBasicHeaderRenderer",
            "musicShelfHeaderRenderer",
            "gridHeaderRenderer"
        ] {
            if let value = header[key] as? [String: Any] { return value }
        }
        return header
    }

    private enum EndpointPreference { case browse, play }

    private func endpoint(
        in renderer: [String: Any],
        preferred: EndpointPreference
    ) -> WebHomeEndpoint? {
        let roots = [
            renderer["navigationEndpoint"],
            renderer["playNavigationEndpoint"],
            renderer["endpoint"],
            renderer["serviceEndpoint"],
            renderer
        ]
        for root in roots {
            guard let dictionary = root as? [String: Any] else { continue }
            if preferred == .play,
               let itemData = dictionary["playlistItemData"] as? [String: Any],
               let videoID = validID(itemData["videoId"]) {
                return WebHomeEndpoint(kind: .video, identifier: videoID)
            }
            if preferred == .play,
               let watch = dictionary["watchEndpoint"] as? [String: Any],
               let videoID = validID(watch["videoId"]) {
                return WebHomeEndpoint(kind: .video, identifier: videoID)
            }
            if preferred == .browse,
               let browse = dictionary["browseEndpoint"] as? [String: Any],
               let browseID = validID(browse["browseId"]) {
                return WebHomeEndpoint(
                    kind: browseID.hasPrefix("UC") ? .channel : .browse,
                    identifier: browseID)
            }
            if preferred == .browse,
               let watch = dictionary["watchEndpoint"] as? [String: Any],
               let playlistID = validID(watch["playlistId"]) {
                return WebHomeEndpoint(kind: .playlist, identifier: playlistID)
            }
            if preferred == .browse,
               let playlist = dictionary["watchPlaylistEndpoint"] as? [String: Any],
               let playlistID = validID(playlist["playlistId"]) {
                return WebHomeEndpoint(kind: .playlist, identifier: playlistID)
            }
        }
        return nil
    }

    private func validID(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty, value.count <= 256,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar.value == 45 || scalar.value == 95
              }) else { return nil }
        return value
    }

    private func textValue(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String {
            return normalizedText(simple)
        }
        guard let runs = dictionary["runs"] as? [Any] else { return nil }
        let joined = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined()
        return normalizedText(joined)
    }

    private func normalizedText(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    private func artworkURLs(in renderer: [String: Any]) -> [String] {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any] else { return [] }
        var candidates: [[String: Any]] = []
        collectThumbnailArrays(thumbnail, depth: 0, output: &candidates)
        var seen = Set<String>()
        return candidates.compactMap { candidate -> String? in
            guard let raw = candidate["url"] as? String,
                  raw.count <= 2_048,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  isAllowedArtworkHost(host),
                  seen.insert(raw).inserted else { return nil }
            return raw
        }.prefix(8).map { $0 }
    }

    private func collectThumbnailArrays(
        _ value: Any,
        depth: Int,
        output: inout [[String: Any]]
    ) {
        guard depth <= 5 else { return }
        if let dictionary = value as? [String: Any] {
            if let thumbnails = dictionary["thumbnails"] as? [Any] {
                output.append(contentsOf: thumbnails.compactMap { $0 as? [String: Any] })
            }
            for child in dictionary.values {
                collectThumbnailArrays(child, depth: depth + 1, output: &output)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectThumbnailArrays(child, depth: depth + 1, output: &output)
            }
        }
    }

    private func isAllowedArtworkHost(_ host: String) -> Bool {
        ["ytimg.com", "googleusercontent.com", "ggpht.com", "youtube.com"]
            .contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func availability(in renderer: [String: Any]) -> WebHomeAvailability {
        let policy = (renderer["musicItemRendererDisplayPolicy"] as? String)?.lowercased()
        let unplayable = textValue(renderer["unplayableText"])?.lowercased()
        let badges = (renderer["badges"] as? [Any])?.compactMap { badge -> String? in
            guard let wrapper = badge as? [String: Any] else { return nil }
            let renderer = wrapper["musicInlineBadgeRenderer"] as? [String: Any]
            return renderer?["accessibilityData"]
                .flatMap { $0 as? [String: Any] }?["accessibilityData"]
                .flatMap { $0 as? [String: Any] }?["label"] as? String
        }.joined(separator: " ").lowercased() ?? ""
        let marker = [policy, unplayable, badges].compactMap { $0 }.joined(separator: " ")
        if marker.contains("private") { return .privateItem }
        if marker.contains("deleted") || marker.contains("removed") { return .deleted }
        if marker.contains("region") || marker.contains("country") { return .regionBlocked }
        if marker.contains("unavailable") || marker.contains("grey_out") { return .unavailable }
        return .available
    }

    private func continuationToken(in renderer: [String: Any]) -> String? {
        if let continuations = renderer["continuations"] as? [Any] {
            for value in continuations {
                guard let wrapper = value as? [String: Any],
                      let next = wrapper["nextContinuationData"] as? [String: Any],
                      let token = boundedToken(next["continuation"]) else { continue }
                return token
            }
        }
        if let contents = renderer["contents"] as? [Any] {
            for value in contents {
                guard let wrapper = value as? [String: Any],
                      let item = wrapper["continuationItemRenderer"] as? [String: Any],
                      let endpoint = item["continuationEndpoint"] as? [String: Any],
                      let command = endpoint["continuationCommand"] as? [String: Any],
                      let token = boundedToken(command["token"]) else { continue }
                return token
            }
        }
        return nil
    }

    private func boundedToken(_ value: Any?) -> String? {
        guard let token = value as? String, !token.isEmpty,
              token.count <= 16_384,
              !token.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return token
    }

    private func layout(
        for rendererKey: String,
        usesResponsiveRenderer: Bool
    ) -> WebHomeSectionLayout {
        switch rendererKey {
        case "musicShelfRenderer": .musicShelf
        case "gridRenderer": .grid
        case "musicPlaylistShelfRenderer", "musicShelfContinuation": .continuationShelf
        default: usesResponsiveRenderer ? .quickPicks : .carousel
        }
    }

    private func stableSectionID(
        rendererKey: String,
        sourceEndpoint: WebHomeEndpoint
    ) -> String {
        let material = "\(rendererKey)|\(sourceEndpoint.kind.rawValue)|\(sourceEndpoint.identifier)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "web-v1-\(digest)"
    }
}

private struct ParseAudit {
    var recognizedContainers = 0
    var invalidContainers = 0
    var recognizedItems = 0
    var invalidItems = 0
}
