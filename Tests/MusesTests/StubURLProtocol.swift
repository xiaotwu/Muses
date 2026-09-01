import Foundation
@testable import Muses

//  Shared URLProtocol stub infrastructure for network-touching test suites.
//
//  Why per-suite subclasses instead of one shared `StubURLProtocol`:
//  Swift Testing runs tests in parallel both *within* and *across* suites. A
//  single process-wide `static var rules` store meant one suite's `reset()`
//  could wipe another suite's rules mid-request, leaking requests to the real
//  network (the root cause of the LyricsService / ArtistEnrichment /
//  MetadataEnricher / YouTubeImport flakes). Catch-all rules (`forHostContaining: ""`)
//  made it worse by swallowing any parallel test's request.
//
//  Fix: each network suite declares its own `final class` subclass with its OWN
//  `static` rule store. Different classes → different storage → suites can run
//  in parallel without interfering. Within a suite, `@Suite(.serialized)` ensures
//  same-host tests don't race each other on the suite-local store. No tests are
//  skipped, no assertions loosened, and no request can reach the network because
//  a suite with no matching rule now fails the request (`.unsupportedURL`) instead
//  of falling through to the real stack.

/// A canned response returned by a stub.
struct StubResponse {
    let statusCode: Int
    let body: Data
    let headers: [String: String]
    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

/// A match predicate + response builder pair.
struct StubRule {
    let matches: (URL) -> Bool
    let respond: (URLRequest) -> StubResponse
}

/// Base providing all `URLProtocol` behavior. Concrete per-suite subclasses
/// supply their own rule store by overriding `rules` and `lock`; everything else
/// (registration, `canInit`, `startLoading`, `makeConfig`) is inherited and
/// dispatches dynamically to the subclass's store.
class StubURLProtocolBase: URLProtocol, @unchecked Sendable {

    // Each subclass overrides these with its own isolated storage.
    class var rules: [StubRule] {
        get { fatalError("StubURLProtocolBase subclass must override rules") }
        set { fatalError("StubURLProtocolBase subclass must override rules") }
    }
    class var lock: NSLock { fatalError("StubURLProtocolBase subclass must override lock") }

    /// Clear this subclass's rules only (other suites are unaffected).
    class func reset() {
        lock.lock(); defer { lock.unlock() }
        rules = []
    }

    // MARK: - Registration (call before creating the URLSession)

    func respond(forHostEndingWith hostSuffix: String,
                 builder: @escaping (URLRequest) -> StubResponse) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var r = Self.rules
        r.append(StubRule(
            matches: { $0.host?.hasSuffix(hostSuffix) == true },
            respond: builder))
        Self.rules = r
    }

    func respond(forHostContaining substring: String,
                 builder: @escaping (URLRequest) -> StubResponse) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var r = Self.rules
        r.append(StubRule(
            matches: { $0.host?.contains(substring) == true },
            respond: builder))
        Self.rules = r
    }

    /// Build a URLSessionConfiguration that routes requests through this
    /// suite's subclass. Call after all `respond(...)` registrations.
    class func makeConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self as AnyClass]
        return config
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock(); defer { lock.unlock() }
        return rules.contains { $0.matches(url) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let rule = Self.rules.first { $0.matches(url) }
        Self.lock.unlock()
        guard let rule = rule else {
            // No matching rule for this suite → fail rather than hit the network.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stub = rule.respond(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // No-op: all work completes synchronously in startLoading.
    }
}