import Foundation
import os

/// 后台执行 yt-dlp 子进程,脱离 `@MainActor`,并对并发数量限流。
///
/// 之前的实现把 `Process.run()` 与 `process.isRunning` 的 20ms 轮询放在 `@MainActor`
/// 上,冷启动 Home 一次可能并发 ~6 个 yt-dlp,每个都把主线程占着轮询。本 runner 把
/// 子进程的全部阻塞操作(`run()` / `waitUntilExit()` / 管道读取)放进 `Task.detached`,
/// 主线程仅在 `await` 处挂起并释放,不再轮询;同时用 actor 内的信号量限制并发进程数。
actor YTDlpRunner {

    /// 生产默认 2,避免冷启动一次起 ~6 个 yt-dlp 拖慢系统;测试可注入。
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 限流后执行子进程,返回 (stdout, stderr)。超时抛 `.timeout`,
    /// 非零退出抛 `.exitCode`,启动失败抛 `.notFound`。
    func run(executablePath: String,
             args: [String],
             timeout: TimeInterval) async throws -> (stdout: String, stderr: String) {
        await acquire()
        defer { release() }
        return try await Self.executeDetached(
            executablePath: executablePath, args: args, timeout: timeout)
    }

    /// 当前在飞进程数(测试/诊断用)。
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
        // 被释放方"让位"唤醒后,槽位已转交,无需再 inFlight += 1。
    }

    private func release() {
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume() // 槽位所有权转交给等待者,inFlight 不变。
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Detached execution

    /// 真正 spawn 子进程,全部在 `Task.detached` 中完成,不触碰任何 actor/主线程。
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

            // 并发读取两个管道,避免大输出撑满管道缓冲区导致死锁。
            let outRead = Task.detached(priority: .utility) { () -> Data in
                outHandle.readDataToEndOfFile()
            }
            let errRead = Task.detached(priority: .utility) { () -> Data in
                errHandle.readDataToEndOfFile()
            }

            do {
                try process.run()
            } catch {
                _ = await outRead.value
                _ = await errRead.value
                throw YTDlpBridge.YTDlpError.notFound
            }

            // 超时看门狗:超时则置标志并 terminate。标志用于区分"我们超时杀的"与
            // "yt-dlp 自身被信号杀死"(后者仍走 exitCode 路径,保留旧行为)。
            let timedOut = OSAllocatedUnfairLock(initialState: false)
            let watchdog = Task.detached(priority: .utility) { () -> Void in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    process.terminate()
                }
            }
            // 阻塞等待进程退出,但本调用在 detached 任务中,不占主线程。
            process.waitUntilExit()
            watchdog.cancel()

            let outData = await outRead.value
            let errData = await errRead.value
            let stdout = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if timedOut.withLock({ $0 }) {
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