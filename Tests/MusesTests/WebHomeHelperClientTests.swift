import Foundation
import Darwin
import Testing
import MusesWebHomeProtocol
@testable import Muses

@Suite("Web Home helper IPC")
struct WebHomeHelperClientTests {
    @Test("successful helper response round-trips over stdin/stdout")
    func success() async throws {
        let response = WebHomeResponse(
            channelID: "UC_one",
            fetchedAt: Date(),
            expiresAt: Date().addingTimeInterval(900),
            capability: .available)
        let helper = try fakeHelper(responseData: JSONEncoder().encode(response))
        let client = WebHomeHelperClient(helperURL: helper, signatureValidator: { _ in true })

        let received = try await client.execute(request(), timeout: .seconds(1))

        #expect(received.channelID == "UC_one")
        #expect(received.capability == .available)
    }

    @Test("signature rejection prevents helper launch")
    func invalidSignature() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-helper-marker-\(UUID().uuidString)")
        let helper = try fakeHelper(scriptBody: "/usr/bin/touch \(marker.path)")
        let client = WebHomeHelperClient(helperURL: helper, signatureValidator: { _ in false })

        await expectError(.invalidHelper) {
            try await client.execute(request(), timeout: .seconds(1))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("timeout terminates an unresponsive helper")
    func timeout() async throws {
        let helper = try fakeHelper(scriptBody: "/bin/sleep 2")
        let client = WebHomeHelperClient(helperURL: helper, signatureValidator: { _ in true })

        await expectError(.timedOut) {
            try await client.execute(request(), timeout: .milliseconds(50))
        }
    }

    @Test("task cancellation terminates the helper distinctly")
    func cancellation() async throws {
        let helper = try fakeHelper(scriptBody: "/bin/sleep 2")
        let client = WebHomeHelperClient(helperURL: helper, signatureValidator: { _ in true })
        let task = Task {
            try await client.execute(request(), timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as WebHomeHelperClientError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(type(of: error))")
        }
    }

    @Test("nonzero exit is a helper crash")
    func crash() async throws {
        let helper = try fakeHelper(scriptBody: "exit 7")
        let client = WebHomeHelperClient(helperURL: helper, signatureValidator: { _ in true })

        await expectError(.helperCrashed(7)) {
            try await client.execute(request(), timeout: .seconds(1))
        }
    }

    @Test("oversized stdout is rejected without decoding")
    func oversizedOutput() async throws {
        let helper = try fakeHelper(
            scriptBody: "/bin/dd if=/dev/zero bs=2048 count=1 2>/dev/null")
        let client = WebHomeHelperClient(
            helperURL: helper,
            maximumOutputBytes: 1024,
            signatureValidator: { _ in true })

        await expectError(.responseTooLarge) {
            try await client.execute(request(), timeout: .seconds(1))
        }
    }

    @Test("protocol mismatch and extra stdout are rejected")
    func strictProtocol() async throws {
        let wrongVersion = WebHomeResponse(
            protocolVersion: WebHomeProtocolVersion.current + 1,
            capability: .unavailable)
        let mismatched = try fakeHelper(responseData: JSONEncoder().encode(wrongVersion))
        let mismatchedClient = WebHomeHelperClient(
            helperURL: mismatched, signatureValidator: { _ in true })
        await expectError(.protocolMismatch) {
            try await mismatchedClient.execute(request(), timeout: .seconds(1))
        }

        var extra = try JSONEncoder().encode(WebHomeResponse(capability: .unavailable))
        extra.append(Data("{}".utf8))
        let noisy = try fakeHelper(responseData: extra)
        let noisyClient = WebHomeHelperClient(helperURL: noisy, signatureValidator: { _ in true })
        await expectError(.malformedResponse) {
            try await noisyClient.execute(request(), timeout: .seconds(1))
        }
    }

    private func request() -> WebHomeRequest {
        WebHomeRequest(
            action: .fetchHome,
            expectedChannelID: "UC_one",
            cookieSource: WebHomeCookieSourceDescriptor(browserName: "safari"),
            locale: "en-US",
            region: "US")
    }

    private func fakeHelper(responseData: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let responseURL = directory.appendingPathComponent("response.json")
        try responseData.write(to: responseURL, options: .atomic)
        return try fakeHelper(
            scriptBody: "/bin/cat \(responseURL.path)",
            directory: directory)
    }

    private func fakeHelper(scriptBody: String, directory: URL? = nil) throws -> URL {
        let directory = try directory ?? temporaryDirectory()
        let helper = directory.appendingPathComponent("MusesWebHomeFakeHelper")
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try Data(script.utf8).write(to: helper, options: .atomic)
        guard chmod(helper.path, S_IRWXU) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return helper
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muses-web-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func expectError(
        _ expected: WebHomeHelperClientError,
        operation: () async throws -> WebHomeResponse
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as WebHomeHelperClientError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(type(of: error))")
        }
    }
}
