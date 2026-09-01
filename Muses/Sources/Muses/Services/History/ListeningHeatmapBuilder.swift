import Foundation

enum ListeningHeatmapBuilder {
    private struct CellKey: Hashable {
        let rowID: String
        let hour: Int
    }

    private struct CellAccumulator {
        var totalMs = 0
        var eventIDs: Set<UUID> = []
        var trackIDs: Set<UUID> = []
        var artists: Set<String> = []
        var slices: [UUID: ListeningHeatmapSlice] = [:]

        mutating func add(_ milliseconds: Int, event: ListeningTimelineEvent) {
            guard milliseconds > 0 else { return }
            totalMs += milliseconds
            eventIDs.insert(event.id)
            trackIDs.insert(event.trackId)
            artists.insert(event.artist)
            let current = slices[event.trackId]
            slices[event.trackId] = .init(
                trackId: event.trackId,
                title: current?.title ?? event.title,
                artist: current?.artist ?? event.artist,
                listenedMs: (current?.listenedMs ?? 0) + milliseconds)
        }
    }

    private struct RowSeed {
        let id: String
        let date: Date?
        let weekday: Int?
        let sampleDayCount: Int
    }

    private struct Segment {
        let rowID: String
        let hour: Int
        let duration: TimeInterval
        let order: Int
    }

    static func build(events: [ListeningTimelineEvent], range: RecapRange,
                      now: Date = .init(), calendar inputCalendar: Calendar = .current)
        -> ListeningHeatmap {
        let calendar = inputCalendar
        let earliest = events.map(\.startedAt).min()
        let displayInterval = range.displayInterval(from: now, calendar: calendar,
                                                    earliest: earliest)
        let dataEnd = min(now, displayInterval.end)
        let dataInterval = DateInterval(start: displayInterval.start,
                                        end: max(displayInterval.start, dataEnd))
        let rowSeeds = makeRows(range: range, interval: displayInterval,
                                now: now, calendar: calendar)
        let rowIDs = Set(rowSeeds.map(\.id))
        var accumulators: [CellKey: CellAccumulator] = [:]

        for event in events where event.listenedMs > 0 {
            let parts = allocations(for: event, inside: dataInterval,
                                    range: range, calendar: calendar)
            for part in parts where rowIDs.contains(part.key.rowID) {
                accumulators[part.key, default: .init()].add(part.milliseconds,
                                                            event: event)
            }
        }

        let rows = rowSeeds.enumerated().map { rowIndex, seed in
            let cells = (0..<24).map { hour in
                let key = CellKey(rowID: seed.id, hour: hour)
                let value = accumulators[key] ?? .init()
                let divisor = range == .allTime ? max(1, seed.sampleDayCount) : 1
                let sortedSlices = value.slices.values.sorted {
                    if $0.listenedMs != $1.listenedMs { return $0.listenedMs > $1.listenedMs }
                    if $0.title != $1.title { return $0.title < $1.title }
                    return $0.trackId.uuidString < $1.trackId.uuidString
                }
                return ListeningHeatmapCell(
                    id: "\(seed.id):\(hour)", rowID: seed.id,
                    rowIndex: rowIndex, hour: hour, totalMs: value.totalMs,
                    intensityMs: Int((Double(value.totalMs) / Double(divisor)).rounded()),
                    eventCount: value.eventIDs.count,
                    trackCount: value.trackIDs.count,
                    artistCount: value.artists.count,
                    sampleDayCount: seed.sampleDayCount,
                    slices: sortedSlices)
            }
            return ListeningHeatmapRow(id: seed.id, index: rowIndex,
                                       date: seed.date, weekday: seed.weekday,
                                       sampleDayCount: seed.sampleDayCount,
                                       cells: cells)
        }
        return .init(range: range, calendarIdentifier: calendar.identifier,
                     timeZoneIdentifier: calendar.timeZone.identifier, rows: rows)
    }

    static func clipped(_ event: ListeningTimelineEvent, to interval: DateInterval)
        -> ListeningTimelineEvent? {
        guard event.listenedMs > 0 else { return nil }
        let eventInterval = effectiveInterval(for: event)
        guard let overlap = intersection(eventInterval, interval), overlap.duration > 0 else {
            if eventInterval.duration == 0, interval.contains(event.startedAt) { return event }
            return nil
        }
        let fraction = eventInterval.duration > 0
            ? overlap.duration / eventInterval.duration : 1
        let milliseconds = min(event.listenedMs,
                               max(0, Int((Double(event.listenedMs) * fraction).rounded())))
        guard milliseconds > 0 else { return nil }
        return .init(id: event.id, trackId: event.trackId,
                     title: event.title, artist: event.artist,
                     startedAt: overlap.start, endedAt: overlap.end,
                     listenedMs: milliseconds,
                     outcome: event.outcome)
    }

    private static func makeRows(range: RecapRange, interval: DateInterval,
                                 now: Date, calendar: Calendar) -> [RowSeed] {
        if range == .allTime {
            var counts: [Int: Int] = [:]
            var day = calendar.startOfDay(for: interval.start)
            let finalDay = calendar.startOfDay(for: max(interval.start, now))
            while day <= finalDay {
                counts[calendar.component(.weekday, from: day), default: 0] += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                      next > day else { break }
                day = next
            }
            return (0..<7).map { offset in
                let weekday = ((calendar.firstWeekday - 1 + offset) % 7) + 1
                return .init(id: "weekday:\(weekday)", date: nil, weekday: weekday,
                             sampleDayCount: counts[weekday] ?? 0)
            }
        }

        var result: [RowSeed] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            result.append(.init(id: dayKey(day, calendar: calendar), date: day,
                                weekday: calendar.component(.weekday, from: day),
                                sampleDayCount: 1))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  next > day else { break }
            day = next
        }
        return result
    }

    private static func allocations(for event: ListeningTimelineEvent,
                                    inside interval: DateInterval,
                                    range: RecapRange,
                                    calendar: Calendar)
        -> [(key: CellKey, milliseconds: Int)] {
        let eventInterval = effectiveInterval(for: event)
        guard let overlap = intersection(eventInterval, interval) else { return [] }
        if eventInterval.duration == 0 {
            guard interval.contains(event.startedAt) else { return [] }
            return [(.init(rowID: rowKey(event.startedAt, range: range,
                                         calendar: calendar),
                           hour: calendar.component(.hour, from: event.startedAt)),
                     event.listenedMs)]
        }
        guard overlap.duration > 0 else { return [] }
        let target = min(event.listenedMs, max(0, Int(
            (Double(event.listenedMs) * overlap.duration / eventInterval.duration).rounded())))
        guard target > 0 else { return [] }

        var segments: [Segment] = []
        var cursor = overlap.start
        var sequence = 0
        while cursor < overlap.end {
            let hourInterval = calendar.dateInterval(of: .hour, for: cursor)
            var boundary = min(hourInterval?.end ?? cursor.addingTimeInterval(3_600),
                               overlap.end)
            if boundary <= cursor {
                boundary = min(cursor.addingTimeInterval(3_600), overlap.end)
            }
            segments.append(.init(
                rowID: rowKey(cursor, range: range, calendar: calendar),
                hour: calendar.component(.hour, from: cursor),
                duration: boundary.timeIntervalSince(cursor), order: sequence))
            sequence += 1
            cursor = boundary
        }
        guard !segments.isEmpty else { return [] }
        let duration = segments.reduce(0) { $0 + $1.duration }
        var shares = segments.map { segment -> (segment: Segment, milliseconds: Int, fraction: Double) in
            let raw = Double(target) * segment.duration / max(duration, .leastNonzeroMagnitude)
            let floor = Int(raw.rounded(.down))
            return (segment, floor, raw - Double(floor))
        }
        var remainder = target - shares.reduce(0) { $0 + $1.milliseconds }
        let remainderOrder = shares.indices.sorted {
            if shares[$0].fraction != shares[$1].fraction {
                return shares[$0].fraction > shares[$1].fraction
            }
            return shares[$0].segment.order < shares[$1].segment.order
        }
        var index = 0
        while remainder > 0, !remainderOrder.isEmpty {
            shares[remainderOrder[index % remainderOrder.count]].milliseconds += 1
            remainder -= 1
            index += 1
        }

        var combined: [CellKey: Int] = [:]
        for share in shares where share.milliseconds > 0 {
            combined[.init(rowID: share.segment.rowID,
                           hour: share.segment.hour), default: 0] += share.milliseconds
        }
        return combined.map { ($0.key, $0.value) }
    }

    private static func effectiveInterval(for event: ListeningTimelineEvent) -> DateInterval {
        let fallbackEnd = event.startedAt.addingTimeInterval(
            TimeInterval(max(0, event.listenedMs)) / 1_000)
        let candidate = event.endedAt ?? fallbackEnd
        return DateInterval(start: event.startedAt,
                            end: max(event.startedAt, candidate))
    }

    private static func intersection(_ lhs: DateInterval, _ rhs: DateInterval)
        -> DateInterval? {
        let start = max(lhs.start, rhs.start)
        let end = min(lhs.end, rhs.end)
        guard end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "date:%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func rowKey(_ date: Date, range: RecapRange,
                               calendar: Calendar) -> String {
        if range == .allTime {
            return "weekday:\(calendar.component(.weekday, from: date))"
        }
        return dayKey(date, calendar: calendar)
    }
}
