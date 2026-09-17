import Foundation
import os

/// Bridges `Process.terminationHandler` to async code with a Dispatch deadline.
/// Dispatch owns the deadline, so timeout delivery does not depend on Swift's
/// cooperative executor having spare capacity under CI or application load.
private final class ProcessDeadline: @unchecked Sendable {
    private enum WaitAction {
        case schedule
        case resume(Bool)
    }

    private enum State {
        case pending
        case waiting(CheckedContinuation<Bool, Never>)
        case finished(Bool)
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    func processDidExit() { finish(timedOut: false) }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let action = state.withLock { state -> WaitAction in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return .schedule
                case .finished(let timedOut):
                    return .resume(timedOut)
                case .waiting:
                    preconditionFailure("ProcessDeadline may only be awaited once")
                }
            }
            switch action {
            case .resume(let timedOut):
                continuation.resume(returning: timedOut)
            case .schedule:
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeout)
                ) { [self] in
                    finish(timedOut: true)
                }
            }
        }
    }

    private func finish(timedOut: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .pending:
                state = .finished(timedOut)
                return nil
            case .waiting(let waiting):
                state = .finished(timedOut)
                return waiting
            case .finished:
                return nil
            }
        }
        continuation?.resume(returning: timedOut)
    }
}

/// Runs yt-dlp subprocesses off the `@MainActor`, with concurrency throttling.
///
/// A previous implementation ran `Process.run()` plus a 20ms `process.isRunning`
/// poll on the `@MainActor`; a cold start of Home could spawn ~6 yt-dlp processes,
/// each pinning the main thread with polling. This runner moves every blocking
/// subprocess operation (`run()` / `waitUntilExit()` / pipe reads) into
/// `Task.detached`, so the main thread just suspends at the `await` instead of
/// polling; a semaphore inside the actor caps the number of concurrent processes.
actor YTDlpRunner {

    /// Production default 2, so a cold start does not launch ~6 yt-dlp processes
    /// at once and bog the system down; injectable for tests.
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Runs a subprocess after throttling, returning (stdout, stderr).
    /// Throws `.timeout` on expiry, `.exitCode` on non-zero exit, and
    /// `.notFound` when the process fails to launch.
    func run(executablePath: String,
             args: [String],
             timeout: TimeInterval) async throws -> (stdout: String, stderr: String) {
        await acquire()
        defer { release() }
        return try await Self.executeDetached(
            executablePath: executablePath, args: args, timeout: timeout)
    }

    /// Number of processes currently in flight (for tests/diagnostics).
    var inFlightCount: Int { inFlight }

    // MARK: - Throttle

    private func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // After the releaser yields the slot and wakes us, ownership has been
        // handed over already; no need to increment inFlight again.
    }

    private func release() {
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume() // Slot ownership transfers to the waiter; inFlight stays unchanged.
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Detached execution

    /// Actually spawns the subprocess; runs entirely in `Task.detached` and
    /// touches no actor or the main thread.
    private static func executeDetached(executablePath: String,
                                        args: [String],
                                        timeout: TimeInterval) async throws
        -> (stdout: String, stderr: String) {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let outHandle = stdoutPipe.fileHandleForReading
            let errHandle = stderrPipe.fileHandleForReading

            // Read both pipes concurrently so large outputs cannot fill the
            // pipe buffers and deadlock.
            let outRead = Task.detached(priority: .utility) { () -> Data in
                outHandle.readDataToEndOfFile()
            }
            let errRead = Task.detached(priority: .utility) { () -> Data in
                errHandle.readDataToEndOfFile()
            }

            let deadline = ProcessDeadline()
            process.terminationHandler = { _ in deadline.processDidExit() }

            do {
                try process.run()
            } catch {
                _ = await outRead.value
                _ = await errRead.value
                throw YTDlpBridge.YTDlpError.notFound
            }

            // A detached Swift watchdog can begin late on a saturated executor.
            // The Dispatch-backed deadline starts from launch deterministically.
            let timedOut = await deadline.wait(timeout: timeout)
            if timedOut, process.isRunning {
                process.terminate()
            }
            // Reap the process before consuming the pipes. Real yt-dlp is one
            // executable; this also keeps the runner's Process lifetime clear.
            process.waitUntilExit()

            let outData = await outRead.value
            let errData = await errRead.value
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if timedOut {
                throw YTDlpBridge.YTDlpError.timeout
            }
            let status = process.terminationStatus
            if status != 0 {
                throw YTDlpBridge.YTDlpError.exitCode(Int(status), stderr)
            }
            return (stdout, stderr)
        }.value
    }
}
