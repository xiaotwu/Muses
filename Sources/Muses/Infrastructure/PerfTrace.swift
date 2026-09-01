import Foundation
import os

/// Lightweight performance tracing: named events and intervals, written to a
/// thread-safe in-memory ring buffer (dumpable as text for before/after
/// metrics) and to `AppLog`.
///
/// Key events traced:
///  - `home.appear` / `home.firstCachedContent` / `home.firstRemoteContent`
///    / `home.gradientReady` / `home.switchReturn` / `artwork.firstVisible`
///
/// `@MainActor`: all call sites are on the main thread (views), which keeps
/// concurrency simple. `OSSignposter` interval names must be StaticStrings, so
/// this uses only a Logger plus the ring buffer; Instruments can observe via
/// the Logger signals on the `com.muses.app` subsystem.
@MainActor
enum PerfTrace {
    struct Record: Sendable {
        let name: String
        let timestamp: Date
        /// Duration in seconds for interval events; nil for instantaneous events.
        let duration: TimeInterval?
    }

    private static var records: [Record] = []
    private static let log = AppLog.for("PerfTrace")

    /// Records an instantaneous event (e.g. "first content available").
    static func event(_ name: String) {
        let stamp = Date()
        records.append(Record(name: name, timestamp: stamp, duration: nil))
        log.info("perf.event \(name) @\(stamp)")
    }

    /// Interval token, consumed by `end(_:)`.
    struct Interval: Sendable {
        let name: String
        let start: Date
    }

    /// Begins a named interval and returns its token.
    static func begin(_ name: String) -> Interval {
        let start = Date()
        log.info("perf.begin \(name) @\(start)")
        return Interval(name: name, start: start)
    }

    /// Ends the interval and records its duration.
    static func end(_ interval: Interval) {
        let end = Date()
        let dur = end.timeIntervalSince(interval.start)
        records.append(Record(name: interval.name, timestamp: interval.start,
                              duration: dur))
        log.info("perf.end \(interval.name) dur=\(dur)s")
    }

    /// Measures the duration (in seconds) of a synchronous closure.
    @discardableResult
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try body()
    }

    /// Snapshot of all current records, in chronological order.
    static func snapshot() -> [Record] { records }

    /// Clears all records.
    static func clear() { records.removeAll() }

    /// Dumps the current snapshot as readable text (for metrics files).
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