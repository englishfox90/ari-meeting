//
//  RecallEngine+Tools.swift — the Slice B structured-tool entity-resolution pre-step for
//  `RecallEngine.prepare` (plan §4.3, `docs/plans/ask-meetings-tools-and-cards.md`). Split into its
//  own file (mirroring `RecallStream.swift`'s precedent of extending `RecallEngine` from a sibling
//  file, same module) purely to keep `RecallEngine.swift` itself from growing past a reasonable
//  file/function length — no behavior here is separate from `prepare`'s call site.
//
import Foundation

extension RecallEngine {
    struct ResolvedEntity {
        var card: RecallCardPayload
        var contextLine: String
    }

    /// Global-scope-only entry point for the Slice B pre-step: classify, then resolve, swallowing
    /// any classifier miss / ambiguous match / DB hiccup into a plain `nil` (byte-identical
    /// fall-through to pre-Slice-B behavior — never a thrown ask failure).
    static func resolveGlobalScopeEntity(question: String, tools: RecallTools) async -> ResolvedEntity? {
        guard let intent = RecallIntentClassifier.classify(question) else { return nil }
        return try? await resolveEntity(intent, tools: tools)
    }

    /// Resolves a classified `Intent` to a real, unambiguous card via `RecallTools`. Returns `nil`
    /// (never a partial/best-guess card) when the extracted candidate doesn't resolve to exactly
    /// one row, or when its follow-up roster read comes back empty — the caller swallows this via
    /// `try?`, so any DB hiccup here degrades to "no card," never a thrown ask failure.
    static func resolveEntity(
        _ intent: RecallIntentClassifier.Intent,
        tools: RecallTools
    ) async throws -> ResolvedEntity? {
        switch intent {
        case let .personMeetings(nameQuery):
            try await resolvePersonMeetings(nameQuery: nameQuery, tools: tools)
        case let .seriesMeetings(titleQuery):
            try await resolveSeriesMeetings(titleQuery: titleQuery, tools: tools)
        case let .meetingLookup(titleQuery):
            try await resolveMeetingLookup(titleQuery: titleQuery, tools: tools)
        }
    }

    private static func resolvePersonMeetings(
        nameQuery: String,
        tools: RecallTools
    ) async throws -> ResolvedEntity? {
        guard let person = try await tools.findPerson(nameContaining: nameQuery) else { return nil }
        let meetings = try await tools.meetings(withPerson: person.id)
        let lastMeetingDate = meetings.first.map { RFC3339.string(from: $0.createdAt) }
        let payload = PersonCardPayload(
            personId: person.id.rawValue,
            displayName: person.displayName,
            role: person.role,
            organization: person.organization,
            lastMeetingDate: lastMeetingDate,
            meetingCount: meetings.count
        )
        let relativeLabel = meetings.first.flatMap { relativeDayAnnotation(for: $0.createdAt) } ?? ""
        // Local-day formatting, NOT `String(prefix(10))` — the raw RFC3339 prefix is the UTC
        // calendar date, which is the wrong local day near midnight (a 23:30 MDT meeting is the next
        // UTC day). `RecallCardDisplay.friendlyDayOnly` converts to the device's real local day.
        let dateNote = RecallCardDisplay.friendlyDayOnly(lastMeetingDate).map {
            " Last met (via calendar) \($0)\(relativeLabel)."
        } ?? ""
        let contextLine = truncateCardContext(
            "Resolved: \(person.displayName) — \(meetings.count) meeting(s) involving them "
                + "(via calendar).\(dateNote)"
        )
        return ResolvedEntity(card: .person(payload), contextLine: contextLine)
    }

    private static func resolveSeriesMeetings(
        titleQuery: String,
        tools: RecallTools
    ) async throws -> ResolvedEntity? {
        guard let series = try await tools.findSeries(titleContaining: titleQuery) else { return nil }
        let meetings = try await tools.meetings(inSeries: series.id, limit: RecallBounds.maxCardSeriesMeetings)
        // The real total, NOT `meetings.count` — that array is capped at `maxCardSeriesMeetings` for
        // bounded context, so `.count`-ing it would silently under-report a series with more members
        // than the cap (a No-Fake-State violation, not an honest bound).
        let totalCount = try await tools.meetingCount(inSeries: series.id)
        let lastMeetingDate = meetings.first.map { RFC3339.string(from: $0.createdAt) }
        let payload = SeriesCardPayload(
            seriesId: series.id.rawValue,
            title: series.title,
            meetingCount: totalCount,
            lastMeetingDate: lastMeetingDate
        )
        let relativeLabel = meetings.first.flatMap { relativeDayAnnotation(for: $0.createdAt) } ?? ""
        let dateNote = RecallCardDisplay.friendlyDayOnly(lastMeetingDate)
            .map { " Last on \($0)\(relativeLabel)." } ?? ""
        let contextLine = truncateCardContext(
            "Resolved: the \"\(series.title)\" series — \(totalCount) meeting(s) recorded.\(dateNote)"
        )
        return ResolvedEntity(card: .series(payload), contextLine: contextLine)
    }

    private static func resolveMeetingLookup(
        titleQuery: String,
        tools: RecallTools
    ) async throws -> ResolvedEntity? {
        guard let meeting = try await tools.findMeeting(titleContaining: titleQuery) else { return nil }
        let hasSummary = try await tools.hasSummary(for: meeting.id)
        let payload = MeetingCardPayload(
            meetingId: meeting.id.rawValue,
            title: meeting.title,
            meetingDate: RFC3339.string(from: meeting.createdAt),
            hasSummary: hasSummary
        )
        let relativeLabel = relativeDayAnnotation(for: meeting.createdAt) ?? ""
        let friendlyDay = RecallCardDisplay.friendlyDayOnly(RFC3339.string(from: meeting.createdAt)) ?? ""
        let contextLine = truncateCardContext(
            "Resolved: the meeting \"\(meeting.title)\" on \(friendlyDay)\(relativeLabel)."
        )
        return ResolvedEntity(card: .meeting(payload), contextLine: contextLine)
    }

    /// Explicit, pre-computed relative-day annotation (" (today)"/" (yesterday)") for a resolved
    /// date. Stated outright rather than left for the model to compute from a bare date string
    /// beside a separate "today's date is..." line — caught live 2026-07-23: a resolved person's
    /// "last met Jul 23, 2026" sitting right next to "Today's date is ... July 23, 2026" was NOT
    /// reliably connected into "yes, that's today" by the model; LLM date arithmetic is not
    /// something to depend on for a fact Swift can just state.
    private static func relativeDayAnnotation(for date: Date) -> String? {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return " (today)"
        }
        if calendar.isDateInYesterday(date) {
            return " (yesterday)"
        }
        return nil
    }

    /// Bounded-context truncation for the tool-resolved fact line (mirrors `PeopleContext`'s own
    /// `truncateChars` — plan §9, "at most one short, terse real-fact block").
    private static func truncateCardContext(_ text: String) -> String {
        let scalars = Recall.scalars(text)
        guard scalars.count > RecallBounds.maxCardContextChars else { return text }
        let head = Recall.string(fromScalars: scalars.prefix(RecallBounds.maxCardContextChars))
        return "\(head)…"
    }
}
