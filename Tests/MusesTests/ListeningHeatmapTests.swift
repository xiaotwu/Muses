import Foundation
import Testing
@testable import Muses

@Suite("Listening heatmap calendar semantics")
struct ListeningHeatmapTests {
    @Test("Today, week, and month use natural calendar intervals")
    func naturalCalendarRanges() throws {
        var calendar = makeCalendar(timeZone: "America/Los_Angeles", firstWeekday: 2)
        let now = try date(2026, 8, 27, 15, 30, calendar: calendar)

        let day = RecapRange.day.displayInterval(from: now, calendar: calendar,
                                                 earliest: nil)
        #expect(calendar.component(.hour, from: day.start) == 0)
        #expect(calendar.dateComponents([.year, .month, .day], from: day.start)
            == DateComponents(year: 2026, month: 8, day: 27))

        let week = RecapRange.week.displayInterval(from: now, calendar: calendar,
                                                   earliest: nil)
        #expect(calendar.component(.weekday, from: week.start) == 2)
        #expect(calendar.dateComponents([.year, .month, .day], from: week.start)
            == DateComponents(year: 2026, month: 8, day: 24))

        let month = ListeningHeatmapBuilder.build(events: [], range: .month,
                                                  now: now, calendar: calendar)
        #expect(month.rows.count == 31)
        #expect(month.rows.allSatisfy { $0.cells.count == 24 })

        calendar.firstWeekday = 1
        let sundayWeek = RecapRange.week.displayInterval(from: now, calendar: calendar,
                                                         earliest: nil)
        #expect(calendar.component(.weekday, from: sundayWeek.start) == 1)
    }

    @Test("Cross-midnight listening is split by actual intersection")
    func crossMidnight() throws {
        let calendar = makeCalendar(timeZone: "UTC", firstWeekday: 2)
        let start = try date(2026, 1, 1, 23, 50, calendar: calendar)
        let end = try date(2026, 1, 2, 0, 10, calendar: calendar)
        let now = try date(2026, 1, 2, 12, 0, calendar: calendar)
        let heatmap = ListeningHeatmapBuilder.build(
            events: [event(start: start, end: end, milliseconds: 1_200_000)],
            range: .week, now: now, calendar: calendar)

        #expect(cell(heatmap, year: 2026, month: 1, day: 1, hour: 23,
                     calendar: calendar)?.totalMs == 600_000)
        #expect(cell(heatmap, year: 2026, month: 1, day: 2, hour: 0,
                     calendar: calendar)?.totalMs == 600_000)
        #expect(heatmap.totalMs == 1_200_000)
    }

    @Test("The same instant maps to the correct local hour in each time zone")
    func timeZoneMapping() throws {
        let utc = makeCalendar(timeZone: "UTC")
        let start = try date(2026, 1, 2, 8, 30, calendar: utc)
        let end = start.addingTimeInterval(1_800)
        let event = event(start: start, end: end, milliseconds: 1_800_000)
        let losAngeles = makeCalendar(timeZone: "America/Los_Angeles")
        let tokyo = makeCalendar(timeZone: "Asia/Tokyo")

        let la = ListeningHeatmapBuilder.build(events: [event], range: .day,
                                               now: end.addingTimeInterval(60),
                                               calendar: losAngeles)
        let jp = ListeningHeatmapBuilder.build(events: [event], range: .day,
                                               now: end.addingTimeInterval(60),
                                               calendar: tokyo)

        #expect(la.nonzeroCells.map(\.hour) == [0])
        #expect(jp.nonzeroCells.map(\.hour) == [17])
    }

    @Test("Spring-forward skips hour 2 while preserving exact duration")
    func springForward() throws {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles")
        let start = try date(2026, 3, 8, 1, 30, calendar: calendar)
        let end = try date(2026, 3, 8, 3, 30, calendar: calendar)
        let now = try date(2026, 3, 8, 4, 0, calendar: calendar)
        let heatmap = ListeningHeatmapBuilder.build(
            events: [event(start: start, end: end, milliseconds: 3_600_000)],
            range: .day, now: now, calendar: calendar)

        #expect(heatmap.rows[0].cells[1].totalMs == 1_800_000)
        #expect(heatmap.rows[0].cells[2].totalMs == 0)
        #expect(heatmap.rows[0].cells[3].totalMs == 1_800_000)
        #expect(heatmap.totalMs == 3_600_000)
    }

    @Test("Fall-back merges both repeated hour-1 intervals into one cell")
    func fallBack() throws {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles")
        let start = try date(2026, 11, 1, 0, 30, calendar: calendar)
        let end = try date(2026, 11, 1, 2, 30, calendar: calendar)
        let now = try date(2026, 11, 1, 3, 0, calendar: calendar)
        let heatmap = ListeningHeatmapBuilder.build(
            events: [event(start: start, end: end, milliseconds: 10_800_000)],
            range: .day, now: now, calendar: calendar)

        #expect(heatmap.rows[0].cells[0].totalMs == 1_800_000)
        #expect(heatmap.rows[0].cells[1].totalMs == 7_200_000)
        #expect(heatmap.rows[0].cells[2].totalMs == 1_800_000)
        #expect(heatmap.totalMs == 10_800_000)
    }

    @Test("All Time uses weekday daily averages without changing exact totals")
    func allTimeAverages() throws {
        let calendar = makeCalendar(timeZone: "UTC", firstWeekday: 2)
        let first = try date(2026, 8, 3, 10, 0, calendar: calendar)
        let second = try date(2026, 8, 10, 10, 0, calendar: calendar)
        let now = try date(2026, 8, 16, 23, 59, calendar: calendar)
        let heatmap = ListeningHeatmapBuilder.build(events: [
            event(start: first, end: first.addingTimeInterval(3_600),
                  milliseconds: 3_600_000),
            event(start: second, end: second.addingTimeInterval(3_600),
                  milliseconds: 3_600_000),
        ], range: .allTime, now: now, calendar: calendar)

        let monday = try #require(heatmap.rows.first { $0.weekday == 2 })
        #expect(monday.sampleDayCount == 2)
        #expect(monday.cells[10].totalMs == 7_200_000)
        #expect(monday.cells[10].intensityMs == 3_600_000)
        #expect(heatmap.totalMs == 7_200_000)
    }

    @Test("Empty data stays a real zero grid and outliers do not rescale other cells")
    func emptyAndFixedScale() throws {
        let calendar = makeCalendar(timeZone: "UTC")
        let now = try date(2026, 4, 2, 18, 0, calendar: calendar)
        let empty = ListeningHeatmapBuilder.build(events: [], range: .day,
                                                  now: now, calendar: calendar)
        #expect(empty.rows.count == 1)
        #expect(empty.nonzeroCells.isEmpty)
        #expect(ListeningHeatmapLevel(milliseconds: 0) == .none)

        let normalStart = try date(2026, 4, 2, 10, 0, calendar: calendar)
        let outlierStart = try date(2026, 4, 2, 12, 0, calendar: calendar)
        let heatmap = ListeningHeatmapBuilder.build(events: [
            event(start: normalStart, end: normalStart.addingTimeInterval(600),
                  milliseconds: 600_000),
            event(start: outlierStart, end: outlierStart.addingTimeInterval(14_400),
                  milliseconds: 14_400_000),
        ], range: .day, now: now, calendar: calendar)
        #expect(ListeningHeatmapLevel(milliseconds: heatmap.rows[0].cells[10].intensityMs)
                == .low)
        #expect(ListeningHeatmapLevel(milliseconds: heatmap.rows[0].cells[12].intensityMs)
                == .peak)
        #expect(heatmap.rows[0].cells[10].totalMs == 600_000)
    }

    private func makeCalendar(timeZone: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int,
                      calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: hour, minute: minute)))
    }

    private func event(start: Date, end: Date, milliseconds: Int) -> ListeningTimelineEvent {
        .init(id: UUID(), trackId: UUID(), title: "Song", artist: "Artist",
              startedAt: start, endedAt: end, listenedMs: milliseconds,
              outcome: .completed)
    }

    private func cell(_ heatmap: ListeningHeatmap, year: Int, month: Int, day: Int,
                      hour: Int, calendar: Calendar) -> ListeningHeatmapCell? {
        heatmap.rows.first { row in
            guard let date = row.date else { return false }
            let values = calendar.dateComponents([.year, .month, .day], from: date)
            return values.year == year && values.month == month && values.day == day
        }?.cells[hour]
    }
}
