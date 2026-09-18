import Foundation

enum InnertubeEndpoint: String, Sendable {
    case browse
    case next
    case search
}

enum InnertubeError: Error, Sendable, Equatable {
    case offline
    case timedOut
    case rateLimited
    case unauthorized
    case responseTooLarge
    case malformedResponse
    case shapeChanged
    case cancelled
}

struct InnertubeHomePage: Sendable {
    let sections: [HomeSection]
    let continuation: String?
    let shelfContinuations: [String: String]
    let parserSchemaVersion: Int
}

protocol InnertubeServing: Sendable {
    func home(continuation: String?) async throws -> InnertubeHomePage
}
