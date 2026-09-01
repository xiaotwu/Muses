import Foundation

public enum WebHomeProtocolVersion {
    public static let current = 1
}

public enum WebHomeAction: String, Codable, Sendable {
    case probeSession
    case fetchHome
    case fetchContinuation
}

public struct WebHomeCookieSourceDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case browser
        case file
    }

    public let kind: Kind
    public let browserName: String?
    public let browserProfile: String?
    public let filePath: String?

    public init(browserName: String, profile: String? = nil) {
        self.kind = .browser
        self.browserName = browserName
        self.browserProfile = profile
        self.filePath = nil
    }

    public init(filePath: String) {
        self.kind = .file
        self.browserName = nil
        self.browserProfile = nil
        self.filePath = filePath
    }
}

public struct WebHomeRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let action: WebHomeAction
    public let expectedChannelID: String
    public let cookieSource: WebHomeCookieSourceDescriptor
    public let locale: String
    public let region: String
    public let timeoutMilliseconds: Int
    public let continuationHandle: String?

    public init(
        protocolVersion: Int = WebHomeProtocolVersion.current,
        action: WebHomeAction,
        expectedChannelID: String,
        cookieSource: WebHomeCookieSourceDescriptor,
        locale: String,
        region: String,
        timeoutMilliseconds: Int = 12_000,
        continuationHandle: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.action = action
        self.expectedChannelID = expectedChannelID
        self.cookieSource = cookieSource
        self.locale = locale
        self.region = region
        self.timeoutMilliseconds = timeoutMilliseconds
        self.continuationHandle = continuationHandle
    }
}

public enum WebHomeErrorCode: String, Codable, Sendable {
    case disabled
    case oauthRequired
    case cookieSourceUnavailable
    case sessionExpired
    case consentOrCaptchaRequired
    case identityUnavailable
    case accountMismatch
    case shapeChanged
    case rateLimited
    case offline
    case timedOut
    case helperCrashed
    case protocolMismatch
    case responseTooLarge
    case malformedResponse
    case cancelled
}

public struct WebHomeError: Codable, Sendable, Equatable {
    public let code: WebHomeErrorCode
    /// A bounded, credential-free diagnostic intended for local UI only.
    public let message: String?

    public init(code: WebHomeErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

public enum WebHomeCapabilityStatus: String, Codable, Sendable {
    case available
    case unavailable
    case rejected
}

public enum WebHomeSectionLayout: String, Codable, Sendable {
    case carousel
    case musicShelf
    case grid
    case quickPicks
    case continuationShelf
}

public enum WebHomeEndpointKind: String, Codable, Sendable {
    case video
    case playlist
    case browse
    case channel
}

public struct WebHomeEndpoint: Codable, Sendable, Hashable {
    public let kind: WebHomeEndpointKind
    public let identifier: String

    public init(kind: WebHomeEndpointKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public enum WebHomeAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case regionBlocked
    case privateItem
    case deleted
}

public struct WebHomeItem: Codable, Sendable, Equatable {
    public let identity: WebHomeEndpoint
    public let title: String
    public let subtitle: String?
    public let browseEndpoint: WebHomeEndpoint?
    public let playEndpoint: WebHomeEndpoint?
    public let artworkURLs: [String]
    public let availability: WebHomeAvailability

    public init(
        identity: WebHomeEndpoint,
        title: String,
        subtitle: String? = nil,
        browseEndpoint: WebHomeEndpoint? = nil,
        playEndpoint: WebHomeEndpoint? = nil,
        artworkURLs: [String] = [],
        availability: WebHomeAvailability = .available
    ) {
        self.identity = identity
        self.title = title
        self.subtitle = subtitle
        self.browseEndpoint = browseEndpoint
        self.playEndpoint = playEndpoint
        self.artworkURLs = artworkURLs
        self.availability = availability
    }
}

public struct WebHomeSection: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let layout: WebHomeSectionLayout
    public let browseEndpoint: WebHomeEndpoint?
    public let playEndpoint: WebHomeEndpoint?
    public let items: [WebHomeItem]
    /// Sensitive, volatile IPC-only material. The main provider replaces this
    /// with an in-memory handle before creating a cacheable Home snapshot.
    public let continuationToken: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        layout: WebHomeSectionLayout,
        browseEndpoint: WebHomeEndpoint? = nil,
        playEndpoint: WebHomeEndpoint? = nil,
        items: [WebHomeItem],
        continuationToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.browseEndpoint = browseEndpoint
        self.playEndpoint = playEndpoint
        self.items = items
        self.continuationToken = continuationToken
    }
}

public struct WebHomeResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let helperVersion: Int
    public let parserSchemaVersion: Int
    public let channelID: String?
    public let fetchedAt: Date?
    public let expiresAt: Date?
    public let capability: WebHomeCapabilityStatus
    public let sections: [WebHomeSection]
    public let error: WebHomeError?

    public init(
        protocolVersion: Int = WebHomeProtocolVersion.current,
        helperVersion: Int = 1,
        parserSchemaVersion: Int = 1,
        channelID: String? = nil,
        fetchedAt: Date? = nil,
        expiresAt: Date? = nil,
        capability: WebHomeCapabilityStatus,
        sections: [WebHomeSection] = [],
        error: WebHomeError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.parserSchemaVersion = parserSchemaVersion
        self.channelID = channelID
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.capability = capability
        self.sections = sections
        self.error = error
    }
}
