//
//  StoredCalendarHintProvider.swift — the Phase-3.5 `SpeakerCountHintProviding` conformer
//  (plan §2.6).
//
//  Prefers the meeting's linked-**participant** count (`meetingParticipant` rows, matching Rust's
//  `count_participants`, `commands.rs:263`) when it is `> 0`, falling back to
//  `CalendarEventRepository.forMeeting(_:)` attendee count when no participants are linked yet
//  (parity-M1: a deliberate divergence from a pure attendee-count read — attendee lists include
//  declines/optional invitees/rooms and can overstate the room, so participants are preferred
//  when they exist). Either source `n >= 2` produces `.upperBound(min(n, 12))`, origin
//  `.calendarAttendees`; a count of `0` or `1` is honestly reported as `nil` — never a fabricated
//  default (No-Fake-State).
//
public struct StoredCalendarHintProvider: SpeakerCountHintProviding {
    private let persons: PersonRepository
    private let calendarEvents: CalendarEventRepository

    public init(database: AppDatabase) {
        persons = database.persons
        calendarEvents = database.calendarEvents
    }

    public func hint(for meetingId: MeetingID) async throws -> ResolvedSpeakerHint? {
        let participantCount = try await persons.participants(inMeeting: meetingId).count
        let count: Int
        if participantCount > 0 {
            count = participantCount
        } else {
            // A meeting can (rarely) link more than one calendar event; take the largest
            // attendee list among them as the best-available signal.
            let events = try await calendarEvents.forMeeting(meetingId)
            count = events.map(\.attendees.count).max() ?? 0
        }
        guard count >= 2 else { return nil }
        return ResolvedSpeakerHint(hint: .clampedUpperBound(count), origin: .calendarAttendees)
    }
}
