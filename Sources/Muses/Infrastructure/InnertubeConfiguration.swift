import Foundation

struct InnertubeClientConfiguration: Sendable {
    let clientName: String
    let clientVersion: String?
    let language: String
    let region: String
    let userAgent: String
    let requestTimeout: TimeInterval
    let maximumResponseBytes: Int

    static var current: InnertubeClientConfiguration {
        InnertubeClientConfiguration(
            clientName: "WEB_REMIX",
            clientVersion: nil,
            language: Locale.current.language.languageCode?.identifier ?? "en",
            region: Locale.current.region?.identifier ?? "US",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
            requestTimeout: 12,
            maximumResponseBytes: 5 * 1024 * 1024)
    }
}
