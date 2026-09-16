import Foundation
import SwiftData

enum ExternalPlaybackRoute: Equatable, Sendable {
    case track(UUID)
    case video(String)

    init?(url: URL) {
        if url.scheme?.lowercased() == "muses" {
            guard url.host == "play", url.user == nil, url.password == nil,
                  url.port == nil, url.path.isEmpty || url.path == "/",
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let identifiers = (parts.queryItems ?? []).filter { ["v", "trackId"].contains($0.name) }
            guard identifiers.count == 1, let value = identifiers.first?.value else { return nil }
            if identifiers[0].name == "trackId" {
                guard let id = UUID(uuidString: value) else { return nil }
                self = .track(id)
            } else {
                guard Self.validVideoID(value) else { return nil }
                self = .video(value)
            }
        } else {
            guard let target = YouTubeShareTarget(url: url), target.kind == .video,
                  Self.validVideoID(target.id) else { return nil }
            self = .video(target.id)
        }
    }

    static func validVideoID(_ id: String) -> Bool {
        id.count == 11 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// One app-lifetime entry for external activation. Superseded metadata work can
/// finish, but only the latest request may change the active playback context.
@Observable @MainActor
final class ExternalPlaybackRouter {
    private let resolve: (ExternalPlaybackRoute) async throws -> TrackSnapshot
    private let playback: PlaybackService
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var pending: ExternalPlaybackRoute?
    var errorMessage: String?

    init(playback: PlaybackService,
         resolve: @escaping (ExternalPlaybackRoute) async throws -> TrackSnapshot) {
        self.playback = playback
        self.resolve = resolve
    }

    convenience init(playback: PlaybackService, importer: YouTubeImportService, container: ModelContainer) {
        self.init(playback: playback) { route in
            let id: UUID
            switch route {
            case .track(let trackID): id = trackID
            case .video(let videoID):
                id = try await importer.importVideo(url: "https://www.youtube.com/watch?v=\(videoID)", saveToLibrary: false)
            }
            try Task.checkCancellation()
            let context = ModelContext(container)
            guard let track = try context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })).first,
                  track.youTubeId != nil else { throw RoutingError.notFound }
            return TrackSnapshot(from: track)
        }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let route = ExternalPlaybackRoute(url: url) else {
            errorMessage = tr("This is not a supported YouTube video link.", "此链接不是受支持的 YouTube 视频链接。", zhHant: "此連結不是支援的 YouTube 影片連結。")
            return false
        }
        guard pending != route else { return true }
        task?.cancel()
        let token = UUID()
        requestID = token
        pending = route
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.pending = nil; self.task = nil } }
            do {
                let track = try await self.resolve(route)
                guard !Task.isCancelled, self.requestID == token else { return }
                if self.playback.transportState.track?.id == track.id {
                    if !self.playback.transportState.isPlaying { self.playback.play() }
                } else {
                    self.playback.playTrack(track, context: [track], from: .songs)
                }
            } catch {
                guard !Task.isCancelled, self.requestID == token else { return }
                self.errorMessage = tr("Unable to open this video. Check the link and try again.", "无法打开此视频，请检查链接后重试。", zhHant: "無法開啟此影片，請檢查連結後重試。")
            }
        }
        return true
    }

    enum RoutingError: Error { case notFound }
}
