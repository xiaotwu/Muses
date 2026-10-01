import Foundation

/// Shares a resolution across focus, queue prefetch, and foreground playback.
/// Cancellation releases one consumer; it never cancels another consumer's work.
@MainActor
final class StreamResolutionCoordinator {
    private struct Request {
        let identity: UUID
        let task: Task<URL, Error>
        var consumers: Set<UUID>
    }
    private let bridge: any YTDlpBridgeProtocol
    private let cache: StreamURLCache
    private var requests: [String: Request] = [:]
    private let log = AppLog.for("StreamResolution")

    init(bridge: any YTDlpBridgeProtocol, cache: StreamURLCache) {
        self.bridge = bridge
        self.cache = cache
    }

    func resolve(videoID: String, quality: String) async throws -> URL {
        try Task.checkCancellation()
        if let url = cache.get(videoId: videoID, quality: quality) { return url }
        let key = StreamURLCache.cacheKey(videoId: videoID, quality: quality)
        let consumer = UUID()
        let identity: UUID
        let task: Task<URL, Error>
        if var request = requests[key] {
            request.consumers.insert(consumer)
            requests[key] = request
            identity = request.identity
            task = request.task
        } else {
            identity = UUID()
            let interactive = YTDlpRequestPriority.interactive
            task = Task { @MainActor [bridge, cache, log] in
                let start = ContinuousClock.now
                let deadline = start.advanced(by: .seconds(20))
                do {
                    let url = try await YTDlpRequestPriority.$interactive.withValue(interactive) {
                        do {
                            return try await bridge.resolveStreamURL(videoId: videoID, quality: quality, timeout: 12)
                        } catch {
                            try Task.checkCancellation()
                            guard StreamResolutionPolicy.shouldRetry(error) else { throw error }
                            let remaining = ContinuousClock.now.duration(to: deadline).seconds
                            guard remaining > 0.25 else { throw error }
                            return try await bridge.resolveStreamURL(videoId: videoID, quality: quality,
                                                                     timeout: min(8, remaining))
                        }
                    }
                    try Task.checkCancellation()
                    cache.set(videoId: videoID, url: url, quality: quality)
                    let elapsed = start.duration(to: .now).seconds
                    log.info("Resolution completed in \(elapsed, privacy: .public)s; foreground=\(interactive, privacy: .public)")
                    return url
                } catch {
                    log.info("Resolution failed after \(start.duration(to: .now).seconds, privacy: .public)s")
                    throw error
                }
            }
            requests[key] = Request(identity: identity, task: task, consumers: [consumer])
        }
        defer { release(key: key, identity: identity, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let url = try await task.value
            try Task.checkCancellation()
            return url
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(key: key, identity: identity, consumer: consumer)
            }
        }
    }

    private func release(key: String, identity: UUID, consumer: UUID) {
        guard var request = requests[key], request.identity == identity else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            requests.removeValue(forKey: key)
            request.task.cancel()
        } else { requests[key] = request }
    }
}

enum StreamResolutionPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        if let error = error as? YTDlpBridge.YTDlpError {
            switch error {
            case .notFound, .parseFailed: return false
            case .timeout: return true
            case .exitCode(_, let message):
                let text = message.lowercased()
                if ["private video", "video unavailable", "removed", "not available in your country",
                    "sign in", "age-restricted", "unsupported url", "requested format is not available",
                    "http error 429"].contains(where: text.contains) { return false }
                return ["timed out", "timeout", "connection", "http error 5", "http error 403"].contains(where: text.contains)
            }
        }
        return true
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
