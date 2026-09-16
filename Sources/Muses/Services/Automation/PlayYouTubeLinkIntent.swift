import AppIntents
import Foundation

/// System automation delegates to the same validated URL route as external links.
@available(macOS 15.0, *)
struct PlayYouTubeLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Play YouTube Link"
    static let description = IntentDescription("Play a YouTube video or song in Muses.")

    @Parameter(title: "YouTube Link")
    var link: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$link) in Muses")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let route = ExternalPlaybackRoute(url: link) else {
            throw LinkIntentError.unsupported
        }
        var url = URLComponents()
        url.scheme = "muses"
        url.host = "play"
        switch route {
        case .track(let id): url.queryItems = [.init(name: "trackId", value: id.uuidString)]
        case .video(let id): url.queryItems = [.init(name: "v", value: id)]
        }
        guard let destination = url.url else { throw LinkIntentError.unsupported }
        return .result(opensIntent: OpenURLIntent(destination))
    }
}

private enum LinkIntentError: LocalizedError {
    case unsupported
    var errorDescription: String? {
        tr("This is not a supported YouTube video link.", "这不是受支持的 YouTube 视频链接。", zhHant: "這不是支援的 YouTube 影片連結。")
    }
}

@available(macOS 15.0, *)
struct MusesAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayYouTubeLinkIntent(),
                    phrases: ["Play a YouTube link in \(.applicationName)"],
                    shortTitle: "Play YouTube Link", systemImageName: "play.rectangle")
    }
}
