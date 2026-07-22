//
//  CalendarWeekLayout.swift — pure week/day layout math (docs/plans/arikit-calendar-ui.md §3),
//  ported from `frontend/src/app/calendar/_components/WeekGrid.tsx:45-117` (overlap clustering,
//  the 15-min minimum-duration clamp, and the all-day exclusive-end-date rule). No UI imports —
//  the view maps minutes → points with its own `hourHeight` constant; this stays geometry-free
//  so it's unit-testable headless (`CalendarWeekLayoutTests`).
//
//  Week start follows the injected `Calendar`'s locale (`calendar.firstWeekday`) — the resolved
//  open decision (plan header) deliberately diverges from the Rust page's hardcoded Monday start.
//
import AriKit
import Foundation

public enum CalendarWeekLayout {
    /// One event positioned within a single day's timed (non-all-day) grid.
    public struct PositionedEvent: Equatable, Sendable {
        public var event: CalendarEvent
        /// Minutes since local midnight, clamped to [0, 24*60] (WeekGrid.tsx's
        /// `minutesSinceMidnight`).
        public var startMinutes: Int
        /// Always `>= startMinutes + 15` — the minimum-duration clamp (WeekGrid.tsx:56).
        public var endMinutes: Int
        /// Column index within this event's overlap cluster.
        public var column: Int
        /// Total column count of this event's overlap cluster — every event in one cluster
        /// shares the same `columnCount` so their widths match (WeekGrid.tsx:69-97).
        public var columnCount: Int

        public init(event: CalendarEvent, startMinutes: Int, endMinutes: Int, column: Int, columnCount: Int) {
            self.event = event
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
            self.column = column
            self.columnCount = columnCount
        }
    }

    /// The 7 consecutive days of the week containing `date`, starting on `calendar.firstWeekday`
    /// (locale-aware; `dateInterval(of:for:)` also keeps this DST-safe, unlike raw
    /// `addingTimeInterval` day math).
    public static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Side-by-side overlap layout for one day's timed (non-all-day) events — a direct port of
    /// `layoutDay` (WeekGrid.tsx:45-97): sort by start (then end), then greedily pack each
    /// transitively-overlapping cluster into the fewest columns (first column whose last event
    /// has already ended), giving every event in a cluster the same `columnCount`.
    public static func timedLayout(for day: Date, events: [CalendarEvent], calendar: Calendar) -> [PositionedEvent] {
        struct WorkItem {
            var event: CalendarEvent
            var startMinutes: Int
            var endMinutes: Int
            var column = 0
            var columnCount = 1
        }

        var items: [WorkItem] = events
            .filter { !$0.isAllDay }
            .filter { calendar.isDate($0.startTime, inSameDayAs: day) }
            .map { event in
                let startMinutes = minutesSinceMidnight(event.startTime, calendar: calendar)
                let rawEndMinutes = minutesSinceMidnight(event.endTime, calendar: calendar)
                let endMinutes = max(startMinutes + 15, rawEndMinutes)
                return WorkItem(event: event, startMinutes: startMinutes, endMinutes: endMinutes)
            }
            .sorted {
                $0.startMinutes != $1.startMinutes
                    ? $0.startMinutes < $1.startMinutes
                    : $0.endMinutes < $1.endMinutes
            }

        var clusterIndices: [Int] = []
        var clusterEnd = -1
        var columnEnds: [Int] = []

        func flush() {
            let columnCount = columnEnds.count
            for index in clusterIndices {
                items[index].columnCount = columnCount
            }
            clusterIndices = []
            columnEnds = []
            clusterEnd = -1
        }

        for index in items.indices {
            if items[index].startMinutes >= clusterEnd {
                flush()
            }
            if let placed = columnEnds.firstIndex(where: { $0 <= items[index].startMinutes }) {
                items[index].column = placed
                columnEnds[placed] = items[index].endMinutes
            } else {
                items[index].column = columnEnds.count
                columnEnds.append(items[index].endMinutes)
            }
            clusterIndices.append(index)
            clusterEnd = max(clusterEnd, items[index].endMinutes)
        }
        flush()

        return items.map {
            PositionedEvent(
                event: $0.event, startMinutes: $0.startMinutes, endMinutes: $0.endMinutes,
                column: $0.column, columnCount: $0.columnCount
            )
        }
    }

    /// All-day events touching `day` — the exclusive-end-date rule (WeekGrid.tsx:102-117): an
    /// event covers `day` when `startTime < (day's next midnight)` AND `endTime >= (day's
    /// midnight)`. A same-day all-day event (`startTime == endTime`, both at midnight) still
    /// matches its one day under this rule.
    public static func allDayEvents(for day: Date, events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { event in
            guard event.isAllDay else { return false }
            return event.startTime < dayEnd && event.endTime >= dayStart
        }
    }

    /// Minutes since local midnight in `calendar`'s timezone, clamped to [0, 24*60] — the Swift
    /// mirror of `minutesSinceMidnight` (WeekGrid.tsx / week.ts), which reads wall-clock
    /// hour/minute only (not a day-boundary-aware offset) — intentionally ported as-is, including
    /// its known limitation for events that cross midnight (`endMinutes` can come out smaller
    /// than `startMinutes`, caught by the `max(startMinutes + 15, …)` clamp above).
    private static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return min(24 * 60, max(0, minutes))
    }
}
