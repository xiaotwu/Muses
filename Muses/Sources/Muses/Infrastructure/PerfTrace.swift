import Foundation
import os

/// 轻量性能追踪:命名事件 + 区间,写入一个线程安全的内存环形缓冲
/// (可 dump 为文本用于 before/after 指标,spec §15/§25)与 `AppLog`。
///
/// 记录的关键事件:
///  - `home.appear` / `home.firstCachedContent` / `home.firstRemoteContent`
///    / `home.gradientReady` / `home.switchReturn` / `artwork.firstVisible`
///
/// `@MainActor`:所有调用点均在主线程(视图),简化并发。`OSSignposter` 的
/// 区间名需 StaticString,故此处只用 Logger + 环形缓冲;Instruments 可通过
/// `com.muses.app` subsystem 的 Logger 信号观察。
@MainActor
enum PerfTrace {
    struct Record: Sendable {
        let name: String
        let timestamp: Date
        /// 区间事件的耗时(秒);瞬时事件为 nil。
        let duration: TimeInterval?
    }

    private static var records: [Record] = []
    private static let log = AppLog.for("PerfTrace")

    /// 记录一个瞬时事件(如「首次有内容」)。
    static func event(_ name: String) {
        let stamp = Date()
        records.append(Record(name: name, timestamp: stamp, duration: nil))
        log.info("perf.event \(name) @\(stamp)")
    }

    /// 区间令牌,用于 `end(_:)`。
    struct Interval: Sendable {
        let name: String
        let start: Date
    }

    /// 开始一个命名区间,返回令牌。
    static func begin(_ name: String) -> Interval {
        let start = Date()
        log.info("perf.begin \(name) @\(start)")
        return Interval(name: name, start: start)
    }

    /// 结束区间并记录耗时。
    static func end(_ interval: Interval) {
        let end = Date()
        let dur = end.timeIntervalSince(interval.start)
        records.append(Record(name: interval.name, timestamp: interval.start,
                              duration: dur))
        log.info("perf.end \(interval.name) dur=\(dur)s")
    }

    /// 测量一个同步闭包的耗时(秒)。
    @discardableResult
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try body()
    }

    /// 当前所有记录的快照(按时间顺序)。
    static func snapshot() -> [Record] { records }

    /// 清空记录。
    static func clear() { records.removeAll() }

    /// 把当前快照 dump 为可读文本(供 `artifacts/` 指标文件)。
    static func dumpText() -> String {
        let recs = snapshot()
        var lines: [String] = ["# PerfTrace snapshot (\(recs.count) records)"]
        let fmt = ISO8601DateFormatter()
        for r in recs {
            if let d = r.duration {
                lines.append("- \(r.name)  start=\(fmt.string(from: r.timestamp))  duration=\(String(format: "%.3f", d))s")
            } else {
                lines.append("- \(r.name)  @\(fmt.string(from: r.timestamp))")
            }
        }
        return lines.joined(separator: "\n")
    }
}