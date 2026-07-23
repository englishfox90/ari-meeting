//
//  RecallTools.swift — the fixed set of deterministic entity-lookup tools for Ask Meetings
//  (plan §4.2, `docs/plans/ask-meetings-tools-and-cards.md`).
//
//  Neither in-scope provider (`.mlx`, `.claudeCLI`) has a trustworthy native tool-calling surface
//  (plan §4.1), so "tool execution" here is plain, deterministic Swift code — a repository query,
//  never something an LLM "calls". `Sendable` value type over injected repository handles, mirroring
//  `HybridSearch`/`Indexer`/`PeopleContext`'s exact convention — safe to call from any isolation
//  domain, no actors, no locks.
//
//  No-Fake-State discipline (plan §4.2/§9): `findPerson`/`findMeeting`/`findSeries` return `nil` for
//  BOTH zero and multiple (ambiguous) matches — an ambiguous name is never silently guessed. Callers
//  (`RecallEngine`) must treat a `nil` result as "nothing to attach," never fall back to a partial or
//  best-guess row.
//
import Foundation

/// Deterministic, repository-backed entity lookups for the Ask-Meetings intent-classifier pipeline
/// (plan §4). No LLM involvement anywhere in this type — every method is a plain DB query.
public struct RecallTools: Sendable {
    private let meetings: MeetingRepository
    private let persons: PersonRepository
    private let series: SeriesRepository
    private let calendarEvents: CalendarEventRepository

    public init(
        meetings: MeetingRepository,
        persons: PersonRepository,
        series: SeriesRepository,
        calendarEvents: CalendarEventRepository
    ) {
        self.meetings = meetings
        self.persons = persons
        self.series = series
        self.calendarEvents = calendarEvents
    }

    // MARK: - Person / meeting / series resolution (ambiguity-safe)

    /// Resolve a person by display-name substring (case-insensitive). Returns `nil` for zero or
    /// more-than-one matches — ambiguity is never silently guessed (No-Fake-State).
    public func findPerson(nameContaining query: String) async throws -> Person? {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return nil }
        let all = try await persons.all()
        let matches = all.filter { Self.normalized($0.displayName).contains(needle) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Resolve a meeting by title substring (case-insensitive). Returns `nil` for zero or
    /// more-than-one matches.
    public func findMeeting(titleContaining query: String) async throws -> Meeting? {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return nil }
        let all = try await meetings.all()
        let matches = all.filter { Self.normalized($0.title).contains(needle) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Resolve a series by title substring (case-insensitive). Returns `nil` for zero or
    /// more-than-one matches.
    public func findSeries(titleContaining query: String) async throws -> Series? {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return nil }
        let all = try await series.all()
        let matches = all.filter { Self.normalized($0.title).contains(needle) }
        return matches.count == 1 ? matches.first : nil
    }

    // MARK: - Real, bounded roster reads (never fabricated)

    /// Every non-deleted meeting `personId` attended, newest first — via the SAME calendar-email-
    /// attendee matching `PeopleContext` already uses (`PeopleContext.appendMeetingScopedLines`),
    /// NOT a fabricated "spoke in the recording" signal (no diarization-speaker-labeling signal
    /// exists at this layer, plan §4.4). Answers "was this person invited to the calendar event
    /// for this meeting," never "did their voice appear in the recording." Empty (never fabricated)
    /// when the person has no email or no calendar-linked meetings.
    public func meetings(withPerson personId: PersonID) async throws -> [Meeting] {
        guard let person = try await persons.find(personId),
              let email = person.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty
        else {
            return []
        }
        let events = try await calendarEvents.all()
        let linkedMeetingIds = Set(events.compactMap { event -> MeetingID? in
            guard let meetingId = event.meetingId else { return nil }
            let attendeeMatches = event.attendees.contains { attendee in
                attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
            }
            return attendeeMatches ? meetingId : nil
        })
        guard !linkedMeetingIds.isEmpty else { return [] }
        // `meetings.all()` is already non-deleted-only + `createdAt DESC` (newest first).
        return try await meetings.all().filter { linkedMeetingIds.contains($0.id) }
    }

    /// The most recent (newest-first) meetings in `seriesId`, capped at `limit` (real, bounded —
    /// never an unbounded read, plan §9 "bounded context"). This caps how many rows are HYDRATED for
    /// context/`lastMeetingDate`, not the true membership size — callers needing an honest total
    /// count must use `meetingCount(inSeries:)` instead of `.count`-ing this array (a series with
    /// more members than `limit` would otherwise silently under-report, a No-Fake-State violation).
    public func meetings(inSeries seriesId: SeriesID, limit: Int) async throws -> [Meeting] {
        guard limit > 0 else { return [] }
        // `orderedMeetingIds` is chronological ASCENDING (oldest first) — reverse for newest first.
        let orderedIds = try await series.orderedMeetingIds(inSeries: seriesId)
        let newestFirstIds = Array(orderedIds.reversed().prefix(limit))
        guard !newestFirstIds.isEmpty else { return [] }
        var resolved: [Meeting] = []
        for id in newestFirstIds {
            if let meeting = try await meetings.find(id) {
                resolved.append(meeting)
            }
        }
        return resolved
    }

    /// The true, real (never capped/estimated) number of meetings in `seriesId` — cheap, since it
    /// only counts IDs without hydrating `Meeting` rows. Use this for any count shown to the user
    /// (e.g. `SeriesCardPayload.meetingCount`); use `meetings(inSeries:limit:)` only for the bounded
    /// roster read that feeds `lastMeetingDate`/context.
    public func meetingCount(inSeries seriesId: SeriesID) async throws -> Int {
        try await series.orderedMeetingIds(inSeries: seriesId).count
    }

    // MARK: - Helpers

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
