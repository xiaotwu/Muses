import Foundation

/// AVFoundation can overestimate an uncached progressive audio item's duration.
/// A resolved Google media URL supplies its own exact duration independently of
/// that estimate. Never trust a similarly named query on unrelated hosts.
enum StreamDurationPolicy {
    static func sourceDuration(_ url: URL) -> TimeInterval? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).filter { $0.name == "dur" }
        guard values.count == 1, let value = values[0].value,
              let seconds = Double(value), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
