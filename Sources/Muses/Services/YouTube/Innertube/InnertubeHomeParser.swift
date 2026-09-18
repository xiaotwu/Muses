import CryptoKit
import Foundation

/// Defensive whitelist parser for the small Innertube surface Muses consumes.
/// Renderer vocabulary is intentionally confined to this file.
struct InnertubeHomeParser: Sendable {
    static let schemaVersion = 1

    private static let containers: Set<String> = [
        "musicCarouselShelfRenderer", "musicShelfRenderer", "gridRenderer",
        "musicPlaylistShelfRenderer", "musicShelfContinuation"
    ]
    private static let items: Set<String> = [
        "musicTwoRowItemRenderer", "musicResponsiveListItemRenderer",
        "musicMultiRowListItemRenderer"
    ]
    private static let traversable: Set<String> = [
        "singleColumnBrowseResultsRenderer", "tabRenderer", "sectionListRenderer",
        "musicQueueRenderer", "musicShelfContinuation"
    ]

    func parse(_ data: Data) throws -> InnertubeHomePage {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw InnertubeError.malformedResponse
        }
        var audit = Audit()
        var sections: [HomeSection] = []
        var shelfContinuations: [String: String] = [:]
        visit(root, audit: &audit, sections: &sections,
              shelfContinuations: &shelfContinuations)
        var seen = Set<String>()
        sections = sections.filter { seen.insert($0.id).inserted }
        guard audit.recognizedContainers > 0,
              audit.recognizedItems > 0,
              !sections.isEmpty,
              audit.invalidContainers * 2 <= audit.recognizedContainers,
              audit.invalidItems * 2 <= audit.recognizedItems else {
            throw InnertubeError.shapeChanged
        }
        return InnertubeHomePage(
            sections: sections,
            continuation: globalContinuation(in: root),
            shelfContinuations: shelfContinuations,
            parserSchemaVersion: Self.schemaVersion)
    }

    private func visit(
        _ value: Any,
        audit: inout Audit,
        sections: inout [HomeSection],
        shelfContinuations: inout [String: String]
    ) {
        if let object = value as? [String: Any] {
            var consumed = Set<String>()
            for key in Self.containers {
                guard let renderer = object[key] as? [String: Any] else { continue }
                consumed.insert(key)
                audit.recognizedContainers += 1
                if let (section, continuation) = parseContainer(
                    key, renderer: renderer, audit: &audit) {
                    sections.append(section)
                    if let continuation { shelfContinuations[section.id] = continuation }
                } else {
                    audit.invalidContainers += 1
                }
            }
            for (key, child) in object where !consumed.contains(key) {
                if key.hasSuffix("Renderer"), !Self.traversable.contains(key) { continue }
                visit(child, audit: &audit, sections: &sections,
                      shelfContinuations: &shelfContinuations)
            }
        } else if let array = value as? [Any] {
            for child in array {
                visit(child, audit: &audit, sections: &sections,
                      shelfContinuations: &shelfContinuations)
            }
        }
    }

    private func parseContainer(
        _ key: String,
        renderer: [String: Any],
        audit: inout Audit
    ) -> (HomeSection, String?)? {
        let candidates = ((renderer["contents"] ?? renderer["items"]) as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []
        var parsed: [DiscoveryItem] = []
        var seen = Set<String>()
        var responsive = false
        for candidate in candidates {
            guard let pair = candidate.first(where: { Self.items.contains($0.key) }),
                  let itemRenderer = pair.value as? [String: Any] else { continue }
            audit.recognizedItems += 1
            responsive = responsive || pair.key == "musicResponsiveListItemRenderer"
            guard let item = parseItem(itemRenderer) else {
                audit.invalidItems += 1
                continue
            }
            guard let identity = item.homeMediaIdentity, seen.insert(identity).inserted else { continue }
            parsed.append(item)
        }
        guard !parsed.isEmpty else { return nil }
        let header = header(in: renderer)
        guard let title = text(header?["title"])
                ?? text(renderer["title"])
                ?? (key == "musicShelfContinuation" ? "More" : nil) else { return nil }
        let subtitle = text(header?["strapline"])
            ?? text(header?["subtitle"])
            ?? text(renderer["subtitle"])
        let endpoint = endpoint(in: header ?? renderer, preferPlay: false)
            ?? endpoint(in: header ?? renderer, preferPlay: true)
            ?? parsed.first.flatMap { item -> HomeCardEndpoint? in
                guard case .youTube(let card) = item else { return nil }
                return card.browseEndpoint ?? card.playEndpoint
            }
        guard let endpoint else { return nil }
        let material = "\(key)|\(endpoint.kind.rawValue)|\(endpoint.identifier)"
        let digest = SHA256.hash(data: Data(material.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let kind: HomeSectionKind = switch key {
        case "musicShelfRenderer": .songGrid
        case "gridRenderer": .mixed
        default: responsive ? .quickPicks : .youTubeCarousel
        }
        let section = HomeSection(
            id: "ytm:FEmusic_home:\(digest)",
            title: title,
            subtitle: subtitle,
            kind: kind,
            items: parsed,
            source: .publicDiscovery,
            schemaVersion: Self.schemaVersion)
        return (section, continuationToken(in: renderer))
    }

    private func parseItem(_ renderer: [String: Any]) -> DiscoveryItem? {
        let columns = (renderer["flexColumns"] as? [Any])?.compactMap { value -> [String: Any]? in
            (value as? [String: Any])?["musicResponsiveListItemFlexColumnRenderer"]
                as? [String: Any]
        } ?? []
        guard let title = text(renderer["title"])
                ?? columns.first.flatMap({ text($0["text"]) }) else { return nil }
        let subtitle = text(renderer["subtitle"])
            ?? columns.dropFirst().compactMap { text($0["text"]) }.first
        let play = endpoint(in: renderer, preferPlay: true)
        let browse = endpoint(in: renderer, preferPlay: false)
        guard let identity = play ?? browse else { return nil }
        return .youTube(YouTubeDiscoveryCard(
            id: "\(identity.kind.rawValue):\(identity.identifier)",
            title: title,
            uploader: subtitle,
            thumbnailURL: artworkURLs(in: renderer).last,
            browseEndpoint: browse,
            playEndpoint: play,
            availability: availability(in: renderer)))
    }

    private func header(in renderer: [String: Any]) -> [String: Any]? {
        guard let value = renderer["header"] as? [String: Any] else { return nil }
        for key in ["musicCarouselShelfBasicHeaderRenderer", "musicShelfHeaderRenderer", "gridHeaderRenderer"] {
            if let header = value[key] as? [String: Any] { return header }
        }
        return value
    }

    private func endpoint(in renderer: [String: Any], preferPlay: Bool) -> HomeCardEndpoint? {
        let roots: [Any?] = [renderer["navigationEndpoint"], renderer["playNavigationEndpoint"],
                             renderer["endpoint"], renderer["serviceEndpoint"], renderer]
        for root in roots {
            guard let object = root as? [String: Any] else { continue }
            if preferPlay,
               let item = object["playlistItemData"] as? [String: Any],
               let video = validID(item["videoId"]) {
                return HomeCardEndpoint(kind: .video, identifier: video)
            }
            if preferPlay,
               let watch = object["watchEndpoint"] as? [String: Any],
               let video = validID(watch["videoId"]) {
                return HomeCardEndpoint(kind: .video, identifier: video)
            }
            if !preferPlay,
               let browse = object["browseEndpoint"] as? [String: Any],
               let id = validID(browse["browseId"]) {
                return HomeCardEndpoint(kind: id.hasPrefix("UC") ? .channel : .browse, identifier: id)
            }
            if !preferPlay,
               let watch = object["watchEndpoint"] as? [String: Any],
               let id = validID(watch["playlistId"]) {
                return HomeCardEndpoint(kind: .playlist, identifier: id)
            }
        }
        return nil
    }

    private func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let raw = (object["simpleText"] as? String)
            ?? (object["runs"] as? [Any])?.compactMap {
                ($0 as? [String: Any])?["text"] as? String
            }.joined()
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 500 else { return nil }
        return trimmed
    }

    private func validID(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 256,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0.value == 45 || $0.value == 95
              }) else { return nil }
        return value
    }

    private func artworkURLs(in renderer: [String: Any]) -> [String] {
        guard let thumbnail = renderer["thumbnail"] else { return [] }
        var values: [[String: Any]] = []
        collectThumbnails(thumbnail, depth: 0, output: &values)
        var seen = Set<String>()
        return values.compactMap { value in
            guard let raw = value["url"] as? String, raw.count <= 2_048,
                  let url = URL(string: raw), url.scheme == "https",
                  let host = url.host?.lowercased(),
                  ["ytimg.com", "googleusercontent.com", "ggpht.com", "youtube.com"]
                    .contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
                  seen.insert(raw).inserted else { return nil }
            return raw
        }.prefix(8).map { $0 }
    }

    private func collectThumbnails(_ value: Any, depth: Int, output: inout [[String: Any]]) {
        guard depth <= 5 else { return }
        if let object = value as? [String: Any] {
            if let thumbnails = object["thumbnails"] as? [Any] {
                output.append(contentsOf: thumbnails.compactMap { $0 as? [String: Any] })
            }
            for child in object.values { collectThumbnails(child, depth: depth + 1, output: &output) }
        } else if let array = value as? [Any] {
            for child in array { collectThumbnails(child, depth: depth + 1, output: &output) }
        }
    }

    private func availability(in renderer: [String: Any]) -> HomeCardAvailability {
        let marker = [renderer["musicItemRendererDisplayPolicy"] as? String,
                      text(renderer["unplayableText"])].compactMap { $0 }.joined(separator: " ").lowercased()
        if marker.contains("private") { return .privateItem }
        if marker.contains("deleted") || marker.contains("removed") { return .deleted }
        if marker.contains("region") || marker.contains("country") { return .regionBlocked }
        if marker.contains("unavailable") || marker.contains("grey_out") { return .unavailable }
        return .available
    }

    private func globalContinuation(in root: Any) -> String? {
        guard let object = root as? [String: Any] else { return nil }
        if let continuation = object["continuationContents"] as? [String: Any] {
            return findContinuation(in: continuation)
        }
        if let contents = object["contents"] as? [String: Any] {
            return findContinuation(in: contents)
        }
        return nil
    }

    private func findContinuation(in value: Any, depth: Int = 0) -> String? {
        guard depth <= 12 else { return nil }
        if let object = value as? [String: Any] {
            if let command = object["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String,
               !token.isEmpty, token.count <= 16_384 { return token }
            for (key, child) in object where !Self.containers.contains(key) {
                if let token = findContinuation(in: child, depth: depth + 1) { return token }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let token = findContinuation(in: child, depth: depth + 1) { return token }
            }
        }
        return nil
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
}

private struct Audit {
    var recognizedContainers = 0
    var invalidContainers = 0
    var recognizedItems = 0
    var invalidItems = 0
}
