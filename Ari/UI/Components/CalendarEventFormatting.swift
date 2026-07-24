//
//  CalendarEventFormatting.swift — shared calendar-event time-range formatting, extracted from
//  `EventDetailSheet` so `LinkedEventCard` / `LinkCalendarEventSheet`
//  (docs/plans/calendar-series-intelligence.md §2.5, Feature 3) reuse it rather than duplicating.
//
import AriKit
import Foundation

enum CalendarEventFormatting {
    /// "All day", or "Nov 3, 2:00 PM – 2:30 PM" (same-day), or "Nov 3, 2:00 PM – Nov 4, 9:00 AM"
    /// (spans days).
    static func timeRangeText(for event: CalendarEvent) -> String {
        if event.isAllDay {
            return "All day"
        }
        let sameDay = Calendar.current.isDate(event.startTime, inSameDayAs: event.endTime)
        let start = event.startTime.formatted(date: .abbreviated, time: .shortened)
        let end = sameDay
            ? event.endTime.formatted(date: .omitted, time: .shortened)
            : event.endTime.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }
}
