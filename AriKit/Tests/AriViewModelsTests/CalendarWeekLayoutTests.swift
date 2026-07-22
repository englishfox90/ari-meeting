//
//  CalendarWeekLayoutTests.swift — docs/plans/arikit-calendar-ui.md §6, tests 7-8. An injected
//  fixed-timezone `Calendar` (America/Denver, Monday-start) so the pure layout math never depends
//  on the host machine's locale/timezone.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("CalendarWeekLayout")
struct CalendarWeekLayoutTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private static func event(id: String, start: Date, end: Date, isAllDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(id), calendarId: "cal-1", title: "Event \(id)",
            startTime: start, endTime: end, isAllDay: isAllDay, attendees: []
        )
    }

    // MARK: - weekDays

    @Test("weekDays returns 7 consecutive days starting on the calendar's first weekday")
    func weekDaysReturnsSevenDaysFromWeekStart() throws {
        let wednesday = Self.day(2026, 7, 15)
        let days = CalendarWeekLayout.weekDays(containing: wednesday, calendar: Self.calendar)
        #expect(days.count == 7)
        // 2026-07-15 is a Wednesday; the Monday-start week begins 2026-07-13.
        #expect(Self.calendar.isDate(days[0], inSameDayAs: Self.day(2026, 7, 13)))
        #expect(Self.calendar.isDate(days[6], inSameDayAs: Self.day(2026, 7, 19)))
    }

    // MARK: - timedLayout — overlap clustering (test 7)

    @Test("disjoint events each get their own single-width column")
    func disjointEventsGetOneColumn() throws {
        let day = Self.day(2026, 7, 15)
        let events = [
            Self.event(id: "a", start: Self.day(2026, 7, 15, hour: 9), end: Self.day(2026, 7, 15, hour: 10)),
            Self.event(id: "b", start: Self.day(2026, 7, 15, hour: 11), end: Self.day(2026, 7, 15, hour: 12))
        ]
        let layout = CalendarWeekLayout.timedLayout(for: day, events: events, calendar: Self.calendar)
        #expect(layout.count == 2)
        for positioned in layout {
            #expect(positioned.column == 0)
            #expect(positioned.columnCount == 1)
        }
    }

    @Test("two overlapping events split into two columns")
    func twoOverlappingEventsSplitIntoTwoColumns() throws {
        let day = Self.day(2026, 7, 15)
        let events = [
            Self.event(id: "a", start: Self.day(2026, 7, 15, hour: 9), end: Self.day(2026, 7, 15, hour: 10)),
            Self.event(
                id: "b", start: Self.day(2026, 7, 15, hour: 9, minute: 30),
                end: Self.day(2026, 7, 15, hour: 10, minute: 30)
            )
        ]
        let layout = CalendarWeekLayout.timedLayout(for: day, events: events, calendar: Self.calendar)
        let eventA = try #require(layout.first { $0.event.id == "a" })
        let eventB = try #require(layout.first { $0.event.id == "b" })
        #expect(eventA.columnCount == 2)
        #expect(eventB.columnCount == 2)
        #expect(eventA.column != eventB.column)
    }

    @Test("a transitive overlap chain shares one column count even where the ends don't directly overlap")
    func transitiveChainSharesColumnCount() throws {
        let day = Self.day(2026, 7, 15)
        let events = [
            // 0-60
            Self.event(id: "a", start: Self.day(2026, 7, 15, hour: 9), end: Self.day(2026, 7, 15, hour: 10)),
            // 30-90 — overlaps a
            Self.event(
                id: "b", start: Self.day(2026, 7, 15, hour: 9, minute: 30),
                end: Self.day(2026, 7, 15, hour: 10, minute: 30)
            ),
            // 80-120 — overlaps b, NOT a
            Self.event(
                id: "c", start: Self.day(2026, 7, 15, hour: 10, minute: 20),
                end: Self.day(2026, 7, 15, hour: 11)
            )
        ]
        let layout = CalendarWeekLayout.timedLayout(for: day, events: events, calendar: Self.calendar)
        let columnCounts = Set(layout.map(\.columnCount))
        #expect(columnCounts == [2])
        // "c" doesn't overlap "a" directly, but reuses "a"'s freed column (0) rather than
        // opening a third column for the whole cluster.
        let eventA = try #require(layout.first { $0.event.id == "a" })
        let eventC = try #require(layout.first { $0.event.id == "c" })
        #expect(eventA.column == eventC.column)
    }

    @Test("a column is reused once its occupant event has ended, within the same cluster")
    func columnReuseAfterEventEnds() throws {
        let day = Self.day(2026, 7, 15)
        let events = [
            // 0-30
            Self.event(
                id: "a", start: Self.day(2026, 7, 15, hour: 9),
                end: Self.day(2026, 7, 15, hour: 9, minute: 30)
            ),
            // 15-60 — overlaps a
            Self.event(
                id: "b", start: Self.day(2026, 7, 15, hour: 9, minute: 15),
                end: Self.day(2026, 7, 15, hour: 10)
            ),
            // 45-75 — starts after a has already ended
            Self.event(
                id: "c", start: Self.day(2026, 7, 15, hour: 9, minute: 45),
                end: Self.day(2026, 7, 15, hour: 10, minute: 15)
            )
        ]
        let layout = CalendarWeekLayout.timedLayout(for: day, events: events, calendar: Self.calendar)
        let eventA = try #require(layout.first { $0.event.id == "a" })
        let eventC = try #require(layout.first { $0.event.id == "c" })
        #expect(eventA.column == eventC.column, "c should reuse a's column once a has ended")
    }

    @Test("events shorter than 15 minutes are clamped to a 15-minute minimum duration")
    func minimumFifteenMinuteDurationClamp() throws {
        let day = Self.day(2026, 7, 15)
        let start = Self.day(2026, 7, 15, hour: 9)
        let end = Self.day(2026, 7, 15, hour: 9, minute: 5)
        let events = [Self.event(id: "a", start: start, end: end)]
        let layout = CalendarWeekLayout.timedLayout(for: day, events: events, calendar: Self.calendar)
        let eventA = try #require(layout.first)
        #expect(eventA.endMinutes - eventA.startMinutes == 15)
    }

    // MARK: - allDayEvents (test 8)

    @Test("a same-day all-day event (start == end) appears on its one day")
    func sameDayAllDayEvent() throws {
        let day = Self.day(2026, 7, 15)
        let event = Self.event(id: "a", start: day, end: day, isAllDay: true)
        let result = CalendarWeekLayout.allDayEvents(for: day, events: [event], calendar: Self.calendar)
        #expect(result.map(\.id) == [event.id])
    }

    @Test("all-day end date is exclusive — a 2-day event's stored end doesn't extend to a 3rd day")
    func exclusiveEndDate() throws {
        // EventKit-style: a 2-day all-day event spanning July 15-16 stores endTime = July 17
        // 00:00 (exclusive). The ported boundary check (`effectiveEnd >= dayStart`,
        // WeekGrid.tsx:117) is `>=` rather than `>`, so the exclusive-end DAY ITSELF still
        // matches (its `dayStart` equals `effectiveEnd` exactly) — a faithful port of the
        // incumbent's actual comparison, not an idealized strict-exclusive rule. Only the day
        // AFTER the exclusive end is definitively excluded.
        let start = Self.day(2026, 7, 15)
        let end = Self.day(2026, 7, 17)
        let event = Self.event(id: "a", start: start, end: end, isAllDay: true)

        let day15 = CalendarWeekLayout.allDayEvents(for: Self.day(2026, 7, 15), events: [event], calendar: Self.calendar)
        let day16 = CalendarWeekLayout.allDayEvents(for: Self.day(2026, 7, 16), events: [event], calendar: Self.calendar)
        let day17 = CalendarWeekLayout.allDayEvents(for: Self.day(2026, 7, 17), events: [event], calendar: Self.calendar)
        let day18 = CalendarWeekLayout.allDayEvents(for: Self.day(2026, 7, 18), events: [event], calendar: Self.calendar)

        #expect(day15.map(\.id) == [event.id])
        #expect(day16.map(\.id) == [event.id])
        #expect(day17.map(\.id) == [event.id], "the ported >= boundary still matches the exclusive-end day itself")
        #expect(day18.isEmpty)
    }

    @Test("a multi-day all-day event appears in every day it spans")
    func multiDaySpanAppearsInEveryDay() throws {
        let start = Self.day(2026, 7, 13)
        let end = Self.day(2026, 7, 16) // exclusive — covers 13, 14, 15 (+ the boundary day, see above)
        let event = Self.event(id: "a", start: start, end: end, isAllDay: true)

        // Offsets 0-3 (July 13-16) all match, including the exclusive-end day itself (offset 3
        // == `end`) under the ported `>=` boundary check.
        for offset in 0 ... 3 {
            let day = Self.calendar.date(byAdding: .day, value: offset, to: start)!
            let result = CalendarWeekLayout.allDayEvents(for: day, events: [event], calendar: Self.calendar)
            #expect(result.map(\.id) == [event.id])
        }
        let dayAfter = Self.calendar.date(byAdding: .day, value: 4, to: start)!
        #expect(CalendarWeekLayout.allDayEvents(for: dayAfter, events: [event], calendar: Self.calendar).isEmpty)
    }
}
