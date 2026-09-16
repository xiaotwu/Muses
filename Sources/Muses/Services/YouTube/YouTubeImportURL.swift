import Foundation

enum YouTubeImportURL: Equatable {
    case video(String)
    case playlist(String)

    init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["youtube.com", "www.youtube.com", "music.youtube.com", "youtu.be"].contains(url.host?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let lists = (components.queryItems ?? []).filter { $0.name == "list" }
        if !lists.isEmpty {
            guard lists.count == 1, let id = lists.first?.value,
                  YouTubeShareTarget(kind: .playlist, id: id) != nil else { return nil }
            self = .playlist(id)
        } else {
            guard let target = YouTubeShareTarget(url: url), target.kind == .video,
                  target.id.count == 11 else { return nil }
            self = .video(target.id)
        }
    }
}
