import Foundation
import os
import Darwin

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
/// polling; cancellable background slots and one foreground slot bound concurrency.
actor YTDlpRunner {

    /// Production default 2, so a cold start does not launch ~6 yt-dlp processes
    /// at once and bog the system down; injectable for tests.
    private let maxConcurrent: Int
    private var inFlight = 0
    private var interactiveInFlight = 0
    private struct Waiter {
        let id: UUID
        let interactive: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Reserve a separate single slot for the user's current selection so
    /// discovery and prefetch cannot queue ahead of first sound.
    func run(executablePath: String, args: [String], timeout: TimeInterval) async throws -> (stdout: String, stderr: String) {
        let interactive = YTDlpRequestPriority.interactive
        let started = Date()
        try await acquire(interactive: interactive, timeout: timeout)
        defer { release(interactive: interactive) }
        try Task.checkCancellation()
        let remaining = timeout - Date().timeIntervalSince(started)
        guard remaining > 0 else { throw YTDlpBridge.YTDlpError.timeout }
        return try await Self.executeDetached(executablePath: executablePath, args: args, timeout: remaining)
    }

    var inFlightCount: Int { inFlight + interactiveInFlight }
    var waitingCount: Int { waiters.count }

    private func acquire(interactive: Bool, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        if interactive ? interactiveInFlight < 1 : inFlight < maxConcurrent {
            if interactive { interactiveInFlight += 1 } else { inFlight += 1 }
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, interactive: interactive, continuation: continuation))
                Task {
                    try? await Task.sleep(for: .seconds(max(0, timeout)))
                    self.timeoutWaiter(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func timeoutWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: YTDlpBridge.YTDlpError.timeout)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(interactive: Bool) {
        if let index = waiters.firstIndex(where: { $0.interactive == interactive }) {
            waiters.remove(at: index).continuation.resume()
        } else if interactive { interactiveInFlight -= 1 }
        else { inFlight -= 1 }
    }

    // MARK: - Detached execution

    /// Actually spawns the subprocess; runs entirely in `Task.detached` and
    /// touches no actor or the main thread.
    private static func executeDetached(executablePath: String,
                                        args: [String],
                                        timeout: TimeInterval) async throws
        -> (stdout: String, stderr: String) {
        let processControl = CancellableYTDlpProcess()
        let worker = Task.detached(priority: .utility) {
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
                try Task.checkCancellation()
                try process.run()
                processControl.started(process)
            } catch {
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                _ = await outRead.value
                _ = await errRead.value
                if error is CancellationError { throw error }
                throw YTDlpBridge.YTDlpError.notFound
            }

            // A detached Swift watchdog can begin late on a saturated executor.
            // The Dispatch-backed deadline starts from launch deterministically.
            let timedOut = await deadline.wait(timeout: timeout)
            if timedOut { processControl.cancel() }
            // Reap the process before consuming the pipes. Real yt-dlp is one
            // executable; this also keeps the runner's Process lifetime clear.
            process.waitUntilExit()

            let outData = await outRead.value
            let errData = await errRead.value
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            try Task.checkCancellation()
            if timedOut {
                throw YTDlpBridge.YTDlpError.timeout
            }
            let status = process.terminationStatus
            if status != 0 {
                throw YTDlpBridge.YTDlpError.exitCode(Int(status), stderr)
            }
            return (stdout, stderr)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            processControl.cancel()
        }
    }
}

/// Task-local intent follows protocol-based engine calls without changing the
/// playback engine or yt-dlp test doubles' public interfaces.
enum YTDlpRequestPriority {
    @TaskLocal static var interactive = false
}

private final class CancellableYTDlpProcess: @unchecked Sendable {
    private struct State { var process: Process?; var cancelled = false }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func started(_ process: Process) {
        let cancelled = state.withLock { state in
            state.process = process
            return state.cancelled
        }
        if cancelled { terminate(process) }
    }

    func cancel() {
        let process = state.withLock { state in
            state.cancelled = true
            return state.process
        }
        if let process { terminate(process) }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
}
