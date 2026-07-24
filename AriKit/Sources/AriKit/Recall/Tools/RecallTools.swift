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
    private let summaries: SummaryRepository

    public init(
        meetings: MeetingRepository,
        persons: PersonRepository,
        series: SeriesRepository,
        calendarEvents: CalendarEventRepository,
        summaries: SummaryRepository
    ) {
        self.meetings = meetings
        self.persons = persons
        self.series = series
        self.calendarEvents = calendarEvents
        self.summaries = summaries
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

    /// EVERY series whose title contains `query` (case-insensitive), newest-updated first, capped
    /// at `limit`. Unlike `findSeries(titleContaining:)` this does NOT collapse ambiguity to `nil`
    /// — it is the disambiguation read: the agentic `find_series` tool lists what matched so the
    /// model can pick one and ask again by id, rather than the tool silently deciding for it or
    /// refusing to answer (2026-07-23 design call). Ambiguity is still never *guessed*; it is
    /// surfaced as real, enumerated options.
    public func seriesMatching(titleContaining query: String, limit: Int) async throws -> [Series] {
        let needle = Self.normalized(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let all = try await series.all()
        return all
            .filter { Self.normalized($0.title).contains(needle) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.self)
    }

    /// A single series by id — the follow-up read after `seriesMatching` listed the options.
    public func series(withId seriesId: SeriesID) async throws -> Series? {
        try await series.find(seriesId)
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

    /// Whether `meetingId` has a real, saved summary — real, not fabricated (drives
    /// `MeetingCardPayload.hasSummary`, which in turn decides whether Slice C's card UI offers a
    /// summary snippet).
    public func hasSummary(for meetingId: MeetingID) async throws -> Bool {
        try await summaries.forMeeting(meetingId) != nil
    }

    // MARK: - Calendar-aware lookup (2026-07-23 fix: "do I have a meeting with X today" must

    // consult the calendar directly, not only the `persons` table — a very recently invited
    // attendee may have no `Person` record yet, which used to silently degrade to a confident-
    // sounding "No" instead of an honest "nothing recorded, but here's what's on the calendar.")

    /// Real calendar events happening TODAY (device-local calendar day — `Calendar.current.
    /// isDateInToday`, never a UTC-naive comparison) whose attendees include a case-insensitive
    /// substring match on `nameQuery`. Independent of whether a `Person` record exists yet or
    /// whether the event is linked to a recorded `Meeting` — answers "is this on my calendar
    /// today," which is a DIFFERENT question from "do I have a saved/recorded meeting" (plan
    /// decision, 2026-07-23: calendar events and recorded meetings are related but never
    /// conflated — a calendar hit here does NOT mean anything was recorded or discussed).
    ///
    /// Ambiguity-safe, matching `findPerson`/`findMeeting`/`findSeries`'s discipline: if today's
    /// matching events name MORE THAN ONE distinct attendee (a case-insensitive-normalized name)
    /// containing `nameQuery`, that's ambiguous — return `[]` rather than guessing which person
    /// was meant. A single matching attendee across one or more of today's events resolves
    /// normally (sorted by `startTime`, oldest first).
    public func calendarEventsToday(
        matchingAttendeeName nameQuery: String,
        now: Date = Date()
    ) async throws -> [CalendarEvent] {
        try await calendarEvents(
            in: Self.calendarWindow(daysBack: 0, daysAhead: 0, now: now),
            matchingAttendeeName: nameQuery
        )
    }

    /// The window-scoped generalization of `calendarEventsToday(matchingAttendeeName:)` — same
    /// attendee/email matching and same ambiguity discipline, over an arbitrary date `range`
    /// instead of only the device-local today (2026-07-23 bug: "when do I NEXT have my 1:1 with
    /// Erin" could not be answered at all, because every calendar read in this type clamped to
    /// today and silently discarded tomorrow's event — see `calendarEvents(in:hour:upcomingOnly:)`).
    public func calendarEvents(
        in range: ClosedRange<Date>,
        matchingAttendeeName nameQuery: String
    ) async throws -> [CalendarEvent] {
        let needle = Self.normalized(nameQuery)
        guard !needle.isEmpty else { return [] }
        // (2026-07-23, plan §3.3) A query containing "@" is treated as an email fragment and
        // matched against `attendee.email` (case-insensitively) instead of `attendee.name` — an
        // agentic tool call may pass either shape (`calendar_events(attendee:)`), and an email is a
        // strictly more precise identifier than a display name when both are available.
        let matchesByEmail = needle.contains("@")
        let inWindow = try await calendarEvents.events(startingIn: range)

        var matchedDistinctNames: Set<String> = []
        var matches: [CalendarEvent] = []
        for event in inWindow {
            let attendeeMatches = event.attendees.filter { attendee in
                if matchesByEmail {
                    guard let email = attendee.email else { return false }
                    return Self.normalized(email).contains(needle)
                }
                guard let name = attendee.name else { return false }
                return Self.normalized(name).contains(needle)
            }
            guard !attendeeMatches.isEmpty else { continue }
            matches.append(event)
            for attendee in attendeeMatches {
                // Distinct-match key is always the (normalized) NAME when available — even for an
                // email-matched query — so ambiguity is judged on "how many distinct people", not
                // "how many distinct email strings" (an attendee with no name still counts via a
                // normalized-email fallback key).
                let key = attendee.name.map(Self.normalized) ?? Self.normalized(attendee.email ?? "")
                matchedDistinctNames.insert(key)
            }
        }
        guard matchedDistinctNames.count <= 1, !matches.isEmpty else { return [] }
        return matches.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Agentic-tools additions (plan §3.3, `docs/plans/ask-meetings-agentic-tools.md`)

    /// Real calendar events happening TODAY (device-local calendar day), optionally narrowed to
    /// events whose `startTime` LOCAL hour matches `hourFilter` (0–23; "6pm" → 18). Sorted by
    /// `startTime`, oldest first. Never fabricated — an empty result is an honest "nothing found",
    /// not a guess (No-Fake-State). This is the missing data path for "who is in the 6pm meeting
    /// later" (plan §1, target query 3) — `calendarEventsToday(matchingAttendeeName:)` alone
    /// requires an attendee-name query and cannot answer a pure time-of-day question.
    public func calendarEvents(today hourFilter: Int? = nil, now: Date = Date()) async throws -> [CalendarEvent] {
        try await calendarEvents(
            in: Self.calendarWindow(daysBack: 0, daysAhead: 0, now: now),
            hour: hourFilter
        )
    }

    /// Real calendar events starting inside `range` (device-local whole days — build it with
    /// `calendarWindow(daysBack:daysAhead:now:)`), optionally narrowed to a local `hour` (0–23;
    /// "6pm" → 18) and/or to events that have not finished yet (`upcomingOnly`). Sorted by
    /// `startTime`, oldest first. Never fabricated — an empty result is an honest "nothing found".
    ///
    /// This is the forward-looking read the today-clamped variants above could not express
    /// (2026-07-23 bug: "when do I NEXT have my 1:1 with Erin" returned only today's agenda,
    /// because tomorrow's event was fetched from the store and then filtered away). The store
    /// itself holds −30/+90 days (`CalendarSyncEngine.backgroundPastDays`/`backgroundFutureDays`),
    /// so a forward window is a pure read — no sync change is involved.
    ///
    /// `upcomingOnly` filters on `endTime > now`, NOT `startTime > now`: a meeting that is
    /// currently in progress is honestly still "upcoming/current", while one that already ended
    /// earlier today is not (2026-07-23: an 11:00 event was reported as the answer to "when do I
    /// next…" at 20:00, because nothing anywhere compared against the current time).
    public func calendarEvents(
        in range: ClosedRange<Date>,
        hour hourFilter: Int? = nil,
        upcomingOnly: Bool = false,
        now: Date = Date()
    ) async throws -> [CalendarEvent] {
        let inWindow = try await calendarEvents.events(startingIn: range)
        let hourFiltered: [CalendarEvent] = if let hourFilter {
            inWindow.filter { Calendar.current.component(.hour, from: $0.startTime) == hourFilter }
        } else {
            inWindow
        }
        let filtered = upcomingOnly ? hourFiltered.filter { $0.endTime > now } : hourFiltered
        return filtered.sorted { $0.startTime < $1.startTime }
    }

    /// A device-local whole-day window: from the START of the day `daysBack` days before `now` to
    /// the END of the day `daysAhead` days after it. `daysBack: 0, daysAhead: 0` is exactly "today"
    /// (equivalent to the `Calendar.isDateInToday` filter these tools used before the window read
    /// existed). Whole-day boundaries — never `now ± N×86400` — so a window is the same set of
    /// calendar days regardless of the time of day it is computed at, and so DST transitions do not
    /// shift it by an hour.
    public static func calendarWindow(daysBack: Int, daysAhead: Int, now: Date = Date()) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let startDay = calendar.date(byAdding: .day, value: -max(daysBack, 0), to: now) ?? now
        let endDay = calendar.date(byAdding: .day, value: max(daysAhead, 0), to: now) ?? now
        let start = calendar.startOfDay(for: startDay)
        // `endOfDay` as the last instant of `endDay`, via the start of the FOLLOWING day minus one
        // second — `Calendar` has no `endOfDay`, and a naive `start + 86399` is wrong across DST.
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)) ?? endDay
        let end = endExclusive.addingTimeInterval(-1)
        return start ... Swift.max(start, end)
    }

    /// Bounded read of a series' running ledger markdown — the accumulated open action items,
    /// decisions, recurring themes and per-person threads the series-detail screen shows. `nil`
    /// when the series has no ledger yet (real, never fabricated).
    ///
    /// Before 2026-07-23 this content was reachable ONLY from inside a series-scoped thread
    /// (`RecallEngine.validate` injects it when `seriesId` is set). A global ask like "how are my
    /// 1:1s with Nia going" therefore could not see it at all, and the model fell back to the
    /// calendar and answered a scheduling question instead of the status question asked.
    /// Truncated at `RecallBounds.maxAgenticTranscriptChars`, matching `summaryMarkdown(for:)`.
    public func seriesLedgerMarkdown(for seriesId: SeriesID) async throws -> String? {
        guard let body = try await series.find(seriesId)?.ledgerMarkdown else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scalars = Recall.scalars(trimmed)
        guard scalars.count > RecallBounds.maxAgenticTranscriptChars else { return trimmed }
        let head = Recall.string(fromScalars: scalars.prefix(RecallBounds.maxAgenticTranscriptChars))
        return "\(head)…"
    }

    /// Bounded read of a meeting's saved summary text — `nil` when there is none (real, never
    /// fabricated). Truncated at `RecallBounds.maxAgenticTranscriptChars` so a tool-fetched summary
    /// can never blow the agentic loop's per-tool-result budget (plan §4.1's `get_meeting_summary`).
    public func summaryMarkdown(for meetingId: MeetingID) async throws -> String? {
        guard let body = try await summaries.forMeeting(meetingId)?.bodyMarkdown else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scalars = Recall.scalars(trimmed)
        guard scalars.count > RecallBounds.maxAgenticTranscriptChars else { return trimmed }
        let head = Recall.string(fromScalars: scalars.prefix(RecallBounds.maxAgenticTranscriptChars))
        return "\(head)…"
    }

    // MARK: - Helpers

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
