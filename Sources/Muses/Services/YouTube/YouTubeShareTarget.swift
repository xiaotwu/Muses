import Foundation

/// Share only a stable, original resource. Search URLs and local UUIDs are not
/// substitutes for a remotely shareable album, artist, or playlist.
struct YouTubeShareTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case video, playlist, channel, browse }
    enum Service: String, CaseIterable, Sendable { case youtube, music }
    let kind: Kind
    let id: String

    init?(kind: Kind, id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
        self.kind = kind
        self.id = id
    }

    init?(url: URL) {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "music.youtube.com", "youtu.be"].contains(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let values = query.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        if host == "youtu.be", path.count == 1 {
            self.init(kind: .video, id: path[0])
        } else if path == ["watch"], let id = value("v") {
            self.init(kind: .video, id: id)
        } else if path == ["playlist"], let id = value("list") {
            self.init(kind: .playlist, id: id)
        } else if path.count == 2 {
            switch path[0] {
            case "shorts", "embed": self.init(kind: .video, id: path[1])
            case "channel": self.init(kind: .channel, id: path[1])
            case "browse": self.init(kind: .browse, id: path[1])
            default: return nil
            }
        } else { return nil }
    }

    func url(on service: Service) -> URL? {
        // Music browse IDs are not interchangeable with regular YouTube URLs.
        guard kind != .browse || service == .music else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = service == .music ? "music.youtube.com" : "www.youtube.com"
        switch kind {
        case .video:
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
        case .playlist:
            components.path = "/playlist"
            components.queryItems = [URLQueryItem(name: "list", value: id)]
        case .channel: components.path = "/channel/" + id
        case .browse: components.path = "/browse/" + id
        }
        return components.url
    }

    enum Platform: String, CaseIterable {
        case facebook = "Facebook", x = "X", email = "Email"
    }

    func platformURL(_ platform: Platform, service: Service) -> URL? {
        guard let link = url(on: service) else { return nil }
        var components: URLComponents
        switch platform {
        case .facebook:
            components = URLComponents(string: "https://www.facebook.com/sharer/sharer.php")!
            components.queryItems = [URLQueryItem(name: "u", value: link.absoluteString)]
        case .x:
            components = URLComponents(string: "https://twitter.com/intent/tweet")!
            components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]
        case .email:
            components = URLComponents(string: "mailto:")!
            components.queryItems = [URLQueryItem(name: "body", value: link.absoluteString)]
        }
        return components.url
    }
}
