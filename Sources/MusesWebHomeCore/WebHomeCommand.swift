import Foundation
import MusesWebHomeProtocol

public struct WebHomeCommand: Sendable {
    public static let helperVersion = 1
    public static let parserSchemaVersion = 1

    private let cookieManager: WebHomeCookieJarManager?
    private let sessionClient: WebHomeSessionClient
    private let payloadParser: WebHomePayloadParser

    public init(ytdlpURL: URL) {
        self.cookieManager = try? WebHomeCookieJarManager(
            exporter: ProcessYTDlpCookieExporter(executableURL: ytdlpURL))
        self.sessionClient = WebHomeSessionClient()
        self.payloadParser = WebHomePayloadParser()
    }

    init(cookieManager: WebHomeCookieJarManager,
         sessionClient: WebHomeSessionClient,
         payloadParser: WebHomePayloadParser = .init()) {
        self.cookieManager = cookieManager
        self.sessionClient = sessionClient
        self.payloadParser = payloadParser
    }

    public func execute(_ request: WebHomeRequest) async -> WebHomeResponse {
        guard request.protocolVersion == WebHomeProtocolVersion.current else {
            return failure(.protocolMismatch)
        }
        guard !request.expectedChannelID
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure(.oauthRequired)
        }
        if request.action == .fetchContinuation,
           request.continuationHandle?.isEmpty != false {
            return failure(.malformedResponse)
        }

        guard let cookieManager else {
            return failure(.cookieSourceUnavailable)
        }
        do {
            return try await cookieManager.withCookieJar(source: request.cookieSource) { jar in
                let session = try await sessionClient.execute(request: request, cookies: jar)
                guard request.action == .probeSession else {
                    guard let payload = session.payload else {
                        return failure(.malformedResponse)
                    }
                    let sections = try payloadParser.parse(payload)
                    let fetchedAt = Date()
                    return WebHomeResponse(
                        helperVersion: Self.helperVersion,
                        parserSchemaVersion: Self.parserSchemaVersion,
                        channelID: session.channelID,
                        fetchedAt: fetchedAt,
                        expiresAt: fetchedAt.addingTimeInterval(15 * 60),
                        capability: .available,
                        sections: sections)
                }
                let fetchedAt = Date()
                return WebHomeResponse(
                    helperVersion: Self.helperVersion,
                    parserSchemaVersion: Self.parserSchemaVersion,
                    channelID: session.channelID,
                    fetchedAt: fetchedAt,
                    expiresAt: fetchedAt.addingTimeInterval(15 * 60),
                    capability: .available)
            }
        } catch let error as WebHomeCoreError {
            return failure(error.code)
        } catch is CancellationError {
            return failure(.cancelled)
        } catch {
            return failure(.offline)
        }
    }

    private func failure(_ code: WebHomeErrorCode) -> WebHomeResponse {
        WebHomeResponse(
            helperVersion: Self.helperVersion,
            parserSchemaVersion: Self.parserSchemaVersion,
            capability: .unavailable,
            error: WebHomeError(code: code))
    }
}
