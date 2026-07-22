//
//  EventKitCalendarSource.swift — the one EventKit toucher (S7, plan §2.1/§3).
//
//  All `EK*` objects are created, queried, and projected into `NativeCalendar`/`NativeEvent`
//  entirely inside this actor's isolation — no EventKit type ever escapes into `AriKit` (the
//  Swift analog of the Rust module keeping objc2 behind `NativeEvent`, `eventkit.rs:1-3`).
//
//  Parity source: `frontend/src-tauri/src/calendar/eventkit.rs`.
//
import AppKit
import AriKit
import EventKit
import Foundation

actor EventKitCalendarSource: CalendarSourcing {
    private let store = EKEventStore()

    /// Class method — no store instance needed, mirrors `eventkit.rs:33-35`.
    func permissionStatus() async -> CalendarPermission {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    /// The modern async API replaces the Rust main-thread + block-keepalive dance
    /// (`eventkit.rs:42-90`) — the runtime owns block lifetime and completion dispatch. On a
    /// refusal, re-read the authoritative status rather than assuming `.denied` (parity:
    /// `eventkit.rs:63-71` — e.g. restricted vs. denied are both "not granted", but honestly
    /// distinct).
    func requestFullAccess() async throws -> CalendarPermission {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            return Self.map(EKEventStore.authorizationStatus(for: .event))
        }
        return .fullAccess
    }

    func listCalendars() async throws -> [NativeCalendar] {
        store.calendars(for: .event).map { calendar in
            NativeCalendar(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                color: Self.hex(from: calendar.color)
            )
        }
    }

    /// Empty `calendarIds` short-circuits to `[]` without ever building a predicate or querying
    /// the store (parity: `eventkit.rs:184-186`).
    func fetchEvents(calendarIds: [String], from start: Date, to end: Date) async throws -> [NativeEvent] {
        guard !calendarIds.isEmpty else { return [] }

        let selected = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        let events = store.events(matching: predicate)

        // Events without a persisted identifier (not yet saved) can't be tracked across syncs —
        // skip them (parity: `eventkit.rs:221-226`).
        return events.compactMap { event in
            guard let id = event.eventIdentifier else { return nil }
            let calendar = event.calendar
            return NativeEvent(
                id: id,
                calendarId: calendar?.calendarIdentifier ?? "",
                calendarTitle: calendar?.title,
                title: event.title ?? "",
                startTime: event.startDate,
                endTime: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                notes: event.notes,
                organizer: event.organizer?.name,
                attendees: (event.attendees ?? []).map(Self.attendee(from:)),
                seriesKey: event.calendarItemExternalIdentifier,
                hasRecurrence: event.hasRecurrenceRules,
                occurrenceDate: event.occurrenceDate,
                isDetached: event.isDetached
            )
        }
    }

    // MARK: - Projection helpers (never leak an EK type past here)

    private static func map(_ status: EKAuthorizationStatus) -> CalendarPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .fullAccess
        // `.writeOnly` has no calendar-read use here; treat as not-yet-authorized for reads
        // (parity: `eventkit.rs:20-30`).
        case .writeOnly: .denied
        @unknown default: .denied
        }
    }

    /// Name from `EKParticipant.name`; email parsed from a `mailto:` URL (parity:
    /// `eventkit.rs:162-177`).
    private static func attendee(from participant: EKParticipant) -> Attendee {
        let email: String? =
            if participant.url.scheme?.lowercased() == "mailto" {
                participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            } else {
                nil
            }
        return Attendee(name: participant.name, email: email)
    }

    /// Reads a calendar's assigned `NSColor` as a portable `#RRGGBB` hex string. Unreadable/
    /// unconvertible colors yield `nil` — never a fabricated color (parity: `eventkit.rs:107-145`,
    /// which reads the CGColor manually; `NSColor` is available to us on macOS and does the same
    /// job without the raw CoreGraphics component reach-around).
    private static func hex(from color: NSColor?) -> String? {
        guard let color, let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func toByte(_ value: CGFloat) -> Int {
            Int((value.clamped(to: 0 ... 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", toByte(red), toByte(green), toByte(blue))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
