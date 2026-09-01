import Foundation
import Security
import Darwin
import MusesWebHomeProtocol

enum WebHomeHelperClientError: Error, Equatable {
    case missingHelper
    case invalidHelper
    case helperBusy
    case timedOut
    case cancelled
    case helperCrashed(Int32)
    case responseTooLarge
    case malformedResponse
    case protocolMismatch

    var failureCode: HomeFetchFailureCode {
        switch self {
        case .timedOut: .timedOut
        case .cancelled: .timedOut
        case .helperCrashed, .helperBusy: .helperCrashed
        case .responseTooLarge: .responseTooLarge
        case .protocolMismatch: .protocolMismatch
        case .missingHelper, .invalidHelper, .malformedResponse: .malformedResponse
        }
    }
}

/// Launches exactly one fixed, signed helper per request. Request/response
/// bodies are never logged. The explicit test initializer is internal so only
/// tests can substitute a fake executable and signature validator.
actor WebHomeHelperClient {
    static let defaultTimeout: Duration = .seconds(12)
    static let maximumOutputBytes = 10 * 1024 * 1024

    private let helperURL: URL
    private let signatureValidator: @Sendable (URL) -> Bool
    private let maximumOutputBytes: Int
    private var activeProcess: ProcessBox?

    init(bundle: Bundle = .main) {
        let expectedURL = Self.bundledHelperURL(in: bundle)
        self.helperURL = expectedURL
        self.signatureValidator = { url in
            WebHomeHelperSignatureValidator.isValid(
                helperURL: url,
                expectedURL: expectedURL,
                mainBundle: bundle)
        }
        self.maximumOutputBytes = Self.maximumOutputBytes
    }

    init(helperURL: URL,
         maximumOutputBytes: Int = WebHomeHelperClient.maximumOutputBytes,
         signatureValidator: @escaping @Sendable (URL) -> Bool) {
        self.helperURL = helperURL
        self.maximumOutputBytes = maximumOutputBytes
        self.signatureValidator = signatureValidator
    }

    static func bundledHelperURL(in bundle: Bundle) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("MusesWebHomeHelper", isDirectory: false)
    }

    func execute(
        _ request: WebHomeRequest,
        timeout: Duration = WebHomeHelperClient.defaultTimeout
    ) async throws -> WebHomeResponse {
        guard activeProcess == nil else { throw WebHomeHelperClientError.helperBusy }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw WebHomeHelperClientError.missingHelper
        }
        guard signatureValidator(helperURL) else {
            throw WebHomeHelperClientError.invalidHelper
        }
        guard request.protocolVersion == WebHomeProtocolVersion.current else {
            throw WebHomeHelperClientError.protocolMismatch
        }

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw WebHomeHelperClientError.malformedResponse
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helperURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = minimalEnvironment()

        let box = ProcessBox(process)
        // Register before launch so even an immediately exiting helper cannot
        // race past observation. Avoid blocking a cooperative Swift task in
        // `waitUntilExit()`, which can strand a test/app task after Foundation
        // has already reaped the subprocess.
        let terminationWaiter = ProcessTerminationWaiter(process: process)
        activeProcess = box
        defer { activeProcess = nil }

        do {
            try process.run()
        } catch {
            throw WebHomeHelperClientError.helperCrashed(-1)
        }

        let stdoutTask = Task.detached(priority: .utility) {
            Self.readLimited(stdout.fileHandleForReading, limit: self.maximumOutputBytes)
        }
        let stderrTask = Task.detached(priority: .utility) {
            Self.readLimited(stderr.fileHandleForReading, limit: 64 * 1024)
        }

        stdin.fileHandleForWriting.write(requestData)
        try? stdin.fileHandleForWriting.close()

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await Self.waitForTermination(
                    box, waiter: terminationWaiter, timeout: timeout)
            } onCancel: {
                box.markCancelledAndTerminate()
            }
        } catch is CancellationError {
            box.markCancelledAndTerminate()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw WebHomeHelperClientError.cancelled
        } catch WebHomeHelperClientError.timedOut {
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw WebHomeHelperClientError.timedOut
        }

        let stdoutResult = await stdoutTask.value
        _ = await stderrTask.value // Drained and deliberately discarded.

        if box.wasCancelled { throw WebHomeHelperClientError.cancelled }
        if box.didTimeOut { throw WebHomeHelperClientError.timedOut }
        guard status == EXIT_SUCCESS else {
            throw WebHomeHelperClientError.helperCrashed(status)
        }
        guard !stdoutResult.exceededLimit else {
            throw WebHomeHelperClientError.responseTooLarge
        }

        let response: WebHomeResponse
        do {
            response = try JSONDecoder().decode(WebHomeResponse.self, from: stdoutResult.data)
        } catch {
            throw WebHomeHelperClientError.malformedResponse
        }
        guard response.protocolVersion == WebHomeProtocolVersion.current else {
            throw WebHomeHelperClientError.protocolMismatch
        }
        return response
    }

    func cancel() {
        activeProcess?.markCancelledAndTerminate()
    }

    private func minimalEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["TMPDIR", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment[key] = value
            }
        }
        return environment
    }

    private static func waitForTermination(
        _ box: ProcessBox,
        waiter: ProcessTerminationWaiter,
        timeout: Duration
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await waiter.wait()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                guard !Task.isCancelled else { throw CancellationError() }
                box.markTimedOutAndTerminate()
                throw WebHomeHelperClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw WebHomeHelperClientError.helperCrashed(-1)
            }
            return first
        }
    }

    private static func readLimited(_ handle: FileHandle, limit: Int) -> LimitedRead {
        var data = Data()
        var exceeded = false
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else { break }
            if data.count + chunk.count <= limit {
                data.append(chunk)
            } else {
                exceeded = true
            }
        }
        return LimitedRead(data: data, exceededLimit: exceeded)
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    init(process: Process) {
        process.terminationHandler = { [weak self] process in
            self?.complete(process.terminationStatus)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32? = lock.withLock {
                if let status { return status }
                self.continuation = continuation
                return nil
            }
            if let completedStatus { continuation.resume(returning: completedStatus) }
        }
    }

    private func complete(_ status: Int32) {
        let pending: CheckedContinuation<Int32, Never>? = lock.withLock {
            self.status = status
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: status)
    }
}

private struct LimitedRead: Sendable {
    let data: Data
    let exceededLimit: Bool
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    init(_ process: Process) {
        self.process = process
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func markCancelledAndTerminate() {
        lock.withLock { cancelled = true }
        terminateIfRunning()
    }

    func markTimedOutAndTerminate() {
        lock.withLock { timedOut = true }
        terminateIfRunning()
    }

    private func terminateIfRunning() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0, Darwin.kill(-pid, SIGTERM) == 0 { return }
        process.terminate()
    }
}

private enum WebHomeHelperSignatureValidator {
    static func isValid(helperURL: URL, expectedURL: URL, mainBundle: Bundle) -> Bool {
        guard helperURL.standardizedFileURL == expectedURL.standardizedFileURL,
              helperURL.path.hasPrefix(mainBundle.bundleURL.standardizedFileURL.path + "/") else {
            return false
        }

        var helperCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            helperURL as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode,
              SecStaticCodeCheckValidity(helperCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
                == errSecSuccess else {
            return false
        }

        guard let mainTeamID = mainBundle.executableURL.flatMap(staticCode(at:)).flatMap(teamID(for:)) else {
            // SwiftPM/ad-hoc development builds have no team identifier, but
            // the helper still had to pass strict code-signature validation.
            return true
        }
        return teamID(for: helperCode) == mainTeamID
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func teamID(for code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier] as? String
    }
}
