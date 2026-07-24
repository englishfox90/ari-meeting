//
//  AskToolset.swift — the 6 tool-first Ask Meetings tools + their per-ask accumulation state
//  (plan §3.2/§4.1, `docs/plans/ask-meetings-agentic-tools.md`).
//
//  Tool EXECUTION is always deterministic Swift code (repository reads via `RecallTools`/
//  `HybridSearch`) — the model only ever REQUESTS a tool by name + JSON arguments
//  (`AgenticToolCall`, the frozen Slice-0 contract); it never runs anything itself. Every result
//  string is bounded (`RecallBounds.maxToolResultChars`) and honest: a zero/ambiguous match, a
//  budget exhaustion, or a tool-level failure all return a real, non-fabricated string the model
//  can read and recover from — never a thrown loop abort (plan §4.3).
//
//  `ToolTurnState` is the ONLY new actor in this plan (plan §7) — required because the dispatch
//  closure crosses into the model client's own generation `Task` as `@Sendable` and must mutate
//  shared per-ask accumulation (sources/cards/iteration count/surfaced meeting ids).
//
import Foundation

/// Per-ask mutable accumulation crossing the `@Sendable` dispatch boundary (plan §3.2/§7). No
/// locks, no `@unchecked Sendable` — actor isolation is the whole story.
public actor ToolTurnState {
    public private(set) var sources: [RecallSource] = []
    public private(set) var cards: [RecallCardPayload] = []
    public private(set) var iterations = 0
    /// Cumulative character count of every tool-result string returned so far this ask (M4, code
    /// review 2026-07-23) — a SEPARATE budget from `iterations`: 8 iterations × the per-tool
    /// `RecallBounds.maxToolResultChars` (16k) cap could otherwise total ~128k characters, enough
    /// to overflow the local model's context window even though each individual result was
    /// bounded. Reuses `RecallBounds.maxContextChars` (48k, the shell's own overall context
    /// budget) rather than inventing a new constant.
    public private(set) var toolResultCharsUsed = 0
    /// Meeting ids a tool result has already exposed to the model THIS turn — `get_meeting_summary`
    /// only accepts an id drawn from this set (the model never mints an id, plan §4.1 [P1]).
    public private(set) var surfacedMeetingIds: Set<MeetingID> = []

    public init() {}

    /// Registers a source found by `search_transcripts`, deduping by (meetingId, a stable prefix of
    /// `matchContext`) and hard-capping at `RecallBounds.maxAgenticSources` — mirrors the frozen
    /// Rust `agent.rs::register_source`. Returns the source's 1-based `[Sn]` index (stable across
    /// repeat registrations of the same source), or `nil` once the cap is reached (the caller must
    /// not print a `[Sn]` label for an uncounted source).
    @discardableResult
    public func registerSource(_ source: RecallSource) -> Int? {
        let dedupeKey = Self.dedupeKey(for: source)
        if let existingIndex = sources.firstIndex(where: { Self.dedupeKey(for: $0) == dedupeKey }) {
            return existingIndex + 1
        }
        guard sources.count < RecallBounds.maxAgenticSources else { return nil }
        sources.append(source)
        return sources.count
    }

    /// Attaches a resolved entity card, deduping by value equality — a tool that resolves the same
    /// entity twice in one turn (e.g. `find_person` called again) never produces a duplicate card.
    /// Silently drops anything past `RecallBounds.maxCardsPerAsk` (dedup runs first) — a global
    /// per-ask cap so an unfiltered agenda call, or several tool calls in one turn, can never
    /// flood the answer with cards (2026-07-23 live-test failure A: an unfiltered `todays_events`
    /// call attached one card per event, stacking 7 cards on a single answer).
    public func attach(_ card: RecallCardPayload) {
        guard !cards.contains(card) else { return }
        guard cards.count < RecallBounds.maxCardsPerAsk else { return }
        cards.append(card)
    }

    /// Records a meeting id a tool result legitimately surfaced this turn (plan §4.1 [P1]).
    public func surface(_ meetingId: MeetingID) {
        surfacedMeetingIds.insert(meetingId)
    }

    /// Whether `meetingId` was surfaced by some tool result already this turn.
    public func isSurfaced(_ meetingId: MeetingID) -> Bool {
        surfacedMeetingIds.contains(meetingId)
    }

    /// Begins one dispatch iteration, enforcing the hard budget
    /// (`RecallBounds.maxAgenticIterations`) that the underlying model-loop (`ChatSession`, or the
    /// prompt-JSON loop) does NOT itself cap (plan §4.3). Returns `true` while under budget; once
    /// exhausted, every subsequent call also returns `false` (the budget never resets mid-turn).
    @discardableResult
    public func beginIteration() -> Bool {
        guard iterations < RecallBounds.maxAgenticIterations else { return false }
        iterations += 1
        return true
    }

    private static func dedupeKey(for source: RecallSource) -> String {
        "\(source.meetingId)|\(source.matchContext.prefix(80))"
    }

    /// Whether the cumulative tool-result character budget still has room for ANOTHER dispatch —
    /// checked BEFORE running a tool (M4), so a request that would push the running total over
    /// `RecallBounds.maxContextChars` is refused instead of executed.
    func hasRemainingToolResultBudget() -> Bool {
        toolResultCharsUsed < RecallBounds.maxContextChars
    }

    /// Adds `charCount` to the cumulative tool-result budget — called once per dispatch, AFTER the
    /// tool actually ran, with the length of its own (already per-tool-bounded) result string.
    func accumulateToolResultChars(_ charCount: Int) {
        toolResultCharsUsed += charCount
    }
}

/// The fixed, 6-tool set + dispatch implementation for tool-first Ask Meetings (plan §4.1). A
/// `Sendable` value type over `RecallTools`/`HybridSearch`/`MeetingRepository` — mirrors every
/// other Recall subsystem's "value type over injected handles" convention. No LLM concept here:
/// this is exactly what `RecallTools` already is, just packaged as `AgenticToolDefinition` +
/// `AgenticToolDispatch` (the frozen Slice-0 contract) instead of direct Swift calls.
public struct AskToolset: Sendable {
    let tools: RecallTools
    let hybridSearch: HybridSearch
    let meetings: MeetingRepository
    /// Series-scope pre-binding: when non-`nil`, `search_transcripts`/`list_recent_meetings` are
    /// restricted to this set of member meetings (mirrors `HybridSearch.globalSearchScoped`).
    let allowedMeetingIds: Set<MeetingID>?
    /// The current instant, injected so `calendar_events`' tense logic ("already ended",
    /// `upcoming_only`) is testable at a FIXED time. Without this a test asserting "an 11:00 event
    /// has ended" would pass or fail depending on the wall-clock hour the suite happened to run at.
    let clock: @Sendable () -> Date

    public init(
        tools: RecallTools,
        hybridSearch: HybridSearch,
        meetings: MeetingRepository,
        allowedMeetingIds: Set<MeetingID>? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tools = tools
        self.hybridSearch = hybridSearch
        self.meetings = meetings
        self.allowedMeetingIds = allowedMeetingIds
        self.clock = clock
    }

    // MARK: - Tool definitions (plan §4.1 — terse, written for a 4B model)

    public var definitions: [AgenticToolDefinition] {
        [
            AgenticToolDefinition(
                name: "search_transcripts",
                description: "Search the user's saved meeting transcripts for text matching a query. Use this when the question needs quotes, details, or context from what was actually discussed.",
                parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}"#
            ),
            AgenticToolDefinition(
                name: "find_person",
                description: "Look up a person by name and their recorded meeting history with the user.",
                parametersJSONSchema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
            ),
            AgenticToolDefinition(
                name: "find_meeting",
                description: "Look up one saved meeting by its title or topic.",
                parametersJSONSchema: #"{"type":"object","properties":{"title_or_topic":{"type":"string"}},"required":["title_or_topic"]}"#
            ),
            AgenticToolDefinition(
                name: "get_meeting_summary",
                description: "Read the saved summary for a meeting id you already saw in another tool's result this turn.",
                parametersJSONSchema: #"{"type":"object","properties":{"meeting_id":{"type":"string"}},"required":["meeting_id"]}"#
            ),
            AgenticToolDefinition(
                name: "calendar_events",
                description: "The user's calendar. Defaults to TODAY only. For anything about the future — \"next\", \"upcoming\", \"tomorrow\", \"this week\" — you MUST pass days_ahead (e.g. 14) and upcoming_only=true, or you will only see today and miss the answer. If the question names a person, ALWAYS pass attendee=<name>. If it names a time of day, pass hour (0-23, e.g. 18 for 6pm). A calendar event means something is SCHEDULED, never that it was recorded or discussed.",
                parametersJSONSchema: #"{"type":"object","properties":{"hour":{"type":"integer"},"attendee":{"type":"string"},"days_ahead":{"type":"integer"},"days_back":{"type":"integer"},"upcoming_only":{"type":"boolean"}}}"#
            ),
            AgenticToolDefinition(
                name: "list_recent_meetings",
                description: "List the user's most recently recorded meetings, newest first.",
                parametersJSONSchema: #"{"type":"object","properties":{"limit":{"type":"integer"}}}"#
            )
        ]
    }

    /// A short, fixed, Swift-computed display label for a tool name — never model text (plan §5.1).
    public static func displayLabel(for toolName: String) -> String {
        switch toolName {
        case "search_transcripts": "Searching transcripts"
        case "find_person": "Looking up person"
        case "find_meeting": "Looking up meeting"
        case "get_meeting_summary": "Reading meeting summary"
        case "calendar_events": "Checking the calendar"
        case "list_recent_meetings": "Listing recent meetings"
        default: "Running \(toolName)"
        }
    }

    // MARK: - Dispatch (← `AgenticToolDispatch`, the frozen Slice-0 contract)

    /// The exhaustion string shared by BOTH the per-ask iteration cap and the cumulative
    /// tool-result character budget (M4) — from the model's point of view they mean the same
    /// thing: stop calling tools and answer from what has already been returned.
    private static let budgetExhaustedResult = "\(AgenticToolResultPrefix.budgetExhausted) Answer now from the information you already have."

    /// Executes one requested tool call. Never throws — an unknown tool, invalid arguments, a
    /// budget exhaustion, or a repository failure all return an honest string result so the model
    /// can recover (plan §4.3).
    public func dispatch(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard await state.beginIteration() else {
            return Self.budgetExhaustedResult
        }
        // M4: a SEPARATE cumulative-character budget, checked BEFORE the tool runs — independent
        // of the iteration cap above (8 small results never trip this; a few large ones can,
        // before the 8th iteration ever arrives).
        guard await state.hasRemainingToolResultBudget() else {
            return Self.budgetExhaustedResult
        }
        let result: String = switch call.name {
        case "search_transcripts":
            await searchTranscripts(call, state: state)
        case "find_person":
            await findPerson(call, state: state)
        case "find_meeting":
            await findMeeting(call, state: state)
        case "get_meeting_summary":
            await getMeetingSummary(call, state: state)
        case "calendar_events":
            await calendarEvents(call, state: state)
        case "list_recent_meetings":
            await listRecentMeetings(call, state: state)
        default:
            "\(AgenticToolResultPrefix.unknownTool) \(call.name)"
        }
        await state.accumulateToolResultChars(Recall.scalars(result).count)
        return result
    }

    // MARK: - search_transcripts

    private struct SearchTranscriptsInput: Decodable {
        var query: String
        var limit: Int?
    }

    private func searchTranscripts(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard let input: SearchTranscriptsInput = Self.decode(call.argumentsJSON) else {
            return "\(AgenticToolResultPrefix.invalidArguments) expected {\"query\": string}."
        }
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "\(AgenticToolResultPrefix.invalidArguments) \"query\" must not be empty." }
        let limit = min(max(input.limit ?? 8, 1), 8)

        let results: [TranscriptSearchResult]
        do {
            results = if let allowedMeetingIds {
                try await hybridSearch.globalSearchScoped(query, allowedMeetingIds: allowedMeetingIds)
            } else {
                try await hybridSearch.globalSearch(query)
            }
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not search transcripts."
        }
        guard !results.isEmpty else { return "No matching transcript excerpts found for that query." }

        var lines: [String] = []
        for result in results.prefix(limit) {
            let source = RecallSource(
                meetingId: result.id,
                title: result.title,
                matchContext: result.matchContext,
                timestamp: result.timestamp,
                meetingDate: result.meetingDate,
                summary: result.summary
            )
            guard let index = await state.registerSource(source) else { continue }
            await state.surface(MeetingID(result.id))
            let dateLabel = RecallCardDisplay.friendlyDayOnly(result.meetingDate) ?? "date unavailable"
            let excerpt = String(result.matchContext.prefix(400))
            // Quote the excerpt so the source meeting (title + date, right after [Sn]) is
            // unmistakably separate from the quoted transcript text — a name appearing INSIDE the
            // quotes is something that meeting's transcript mentions, never proof the user
            // attended a meeting WITH that person (2026-07-23 live-test failure B: the model read
            // "…contract sent to Landon…" in a QA-Alignment excerpt as evidence of a meeting WITH
            // Landon).
            lines.append("[S\(index)] \(result.title) (\(dateLabel)): \"\(excerpt)\"")
        }
        guard !lines.isEmpty else {
            return "No matching transcript excerpts found (the source limit for this ask was already reached)."
        }
        return Self.bound(lines.joined(separator: "\n\n"))
    }

    // MARK: - find_person

    private struct FindPersonInput: Decodable {
        var name: String
    }

    private func findPerson(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard let input: FindPersonInput = Self.decode(call.argumentsJSON) else {
            return "\(AgenticToolResultPrefix.invalidArguments) expected {\"name\": string}."
        }
        let person: Person?
        do {
            person = try await tools.findPerson(nameContaining: input.name)
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not look up that person."
        }
        guard let person else {
            return "No unique person matched \"\(input.name)\"."
        }
        let meetings: [Meeting] = await (try? tools.meetings(withPerson: person.id)) ?? []
        let lastMeetingDate = meetings.first.map { RFC3339.string(from: $0.createdAt) }
        let payload = PersonCardPayload(
            personId: person.id.rawValue,
            displayName: person.displayName,
            role: person.role,
            organization: person.organization,
            lastMeetingDate: lastMeetingDate,
            meetingCount: meetings.count
        )
        await state.attach(.person(payload))

        var lines: [String] = []
        var header = "\(person.displayName)"
        if let role = person.role, !role.isEmpty {
            header += ", \(role)"
        }
        header += " — \(RecallCardDisplay.meetingCountLabel(meetings.count)) involving them (via calendar)"
        if let friendly = RecallCardDisplay.friendlyDayOnly(lastMeetingDate) {
            header += ", last met \(friendly)"
        }
        lines.append("\(header).")

        // [P1] Surface this person's ≤3 most recent meetings as "id / title / date" lines, and
        // record each id as surfaced — without this, `get_meeting_summary` is unreachable from a
        // person lookup (the "recap my last meeting with X" flow, plan §1/§8.6.1).
        let recent = Array(meetings.prefix(3))
        if !recent.isEmpty {
            lines.append("Recent meetings:")
            for meeting in recent {
                await state.surface(meeting.id)
                let date = RecallCardDisplay.friendlyDayOnly(RFC3339.string(
                    from: meeting.createdAt
                )) ?? "date unavailable"
                lines.append("\(meeting.id.rawValue) / \(meeting.title) / \(date)")
            }
        }
        return Self.bound(lines.joined(separator: "\n"))
    }

    // MARK: - find_meeting

    private struct FindMeetingInput: Decodable {
        var titleOrTopic: String
        enum CodingKeys: String, CodingKey {
            case titleOrTopic = "title_or_topic"
        }
    }

    private func findMeeting(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard let input: FindMeetingInput = Self.decode(call.argumentsJSON) else {
            return "\(AgenticToolResultPrefix.invalidArguments) expected {\"title_or_topic\": string}."
        }
        let meeting: Meeting?
        do {
            meeting = try await tools.findMeeting(titleContaining: input.titleOrTopic)
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not look up that meeting."
        }
        guard let meeting else {
            return "No unique meeting matched \"\(input.titleOrTopic)\"."
        }
        let hasSummary = await (try? tools.hasSummary(for: meeting.id)) ?? false
        let payload = MeetingCardPayload(
            meetingId: meeting.id.rawValue,
            title: meeting.title,
            meetingDate: RFC3339.string(from: meeting.createdAt),
            hasSummary: hasSummary
        )
        await state.attach(.meeting(payload))
        await state.surface(meeting.id)
        let date = RecallCardDisplay.friendlyDayOnly(RFC3339.string(from: meeting.createdAt)) ?? "date unavailable"
        let summaryNote = hasSummary ? " (has a saved summary)" : " (no saved summary yet)"
        return Self.bound("\(meeting.id.rawValue) / \(meeting.title) / \(date)\(summaryNote)")
    }

    // MARK: - get_meeting_summary

    private struct GetMeetingSummaryInput: Decodable {
        var meetingId: String
        enum CodingKeys: String, CodingKey {
            case meetingId = "meeting_id"
        }
    }

    private func getMeetingSummary(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard let input: GetMeetingSummaryInput = Self.decode(call.argumentsJSON) else {
            return "\(AgenticToolResultPrefix.invalidArguments) expected {\"meeting_id\": string}."
        }
        let meetingId = MeetingID(input.meetingId)
        // [P1] Only a meeting id a tool result ALREADY surfaced this turn is honored — the model
        // never mints an id from nowhere.
        guard await state.isSurfaced(meetingId) else {
            return "Unknown meeting id — only an id surfaced earlier this turn by another tool can be used here."
        }
        let summary: String?
        do {
            summary = try await tools.summaryMarkdown(for: meetingId)
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not read that meeting's summary."
        }
        guard let summary else {
            return "That meeting has no saved summary yet."
        }
        return Self.bound(summary)
    }

    // MARK: - calendar_events

    private struct CalendarEventsInput: Decodable {
        var hour: Int?
        var attendee: String?
        var daysAhead: Int?
        var daysBack: Int?
        var upcomingOnly: Bool?
        enum CodingKeys: String, CodingKey {
            case hour
            case attendee
            case daysAhead = "days_ahead"
            case daysBack = "days_back"
            case upcomingOnly = "upcoming_only"
        }
    }

    /// Hard ceiling on how far ahead/back one call may look — the store holds −30/+90 days, but an
    /// unbounded window would let a single call return months of events and blow the per-result
    /// budget. Clamped (not rejected) so an over-eager `days_ahead: 365` still answers honestly
    /// over the window it did search, which the result text states outright.
    private static let maxCalendarWindowDays = 30

    private func calendarEvents(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        let input: CalendarEventsInput = Self.decode(call.argumentsJSON) ?? CalendarEventsInput()
        if let hour = input.hour, !(0 ... 23).contains(hour) {
            return "\(AgenticToolResultPrefix.invalidArguments) \"hour\" must be 0-23."
        }
        let attendee = input.attendee?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttendeeFilter = attendee.map { !$0.isEmpty } ?? false
        let upcomingOnly = input.upcomingOnly ?? false
        // Default window is TODAY (`0`/`0`) — the pre-2026-07-23 behavior, preserved so an
        // unqualified "what's on my calendar" doesn't suddenly dump a fortnight. A forward-looking
        // question must say so via `days_ahead`; `upcoming_only` alone also implies a forward
        // question, so it widens the default to a fortnight rather than uselessly meaning
        // "the rest of today" (a weak model reliably passes one or the other, not always both).
        let defaultAhead = upcomingOnly ? 14 : 0
        let daysAhead = min(max(input.daysAhead ?? defaultAhead, 0), Self.maxCalendarWindowDays)
        let daysBack = min(max(input.daysBack ?? 0, 0), Self.maxCalendarWindowDays)
        let now = clock()
        let window = RecallTools.calendarWindow(daysBack: daysBack, daysAhead: daysAhead, now: now)
        let isTodayOnly = daysAhead == 0 && daysBack == 0
        let wasFiltered = hasAttendeeFilter || input.hour != nil

        var events: [CalendarEvent]
        do {
            if hasAttendeeFilter, let attendee {
                events = try await tools.calendarEvents(in: window, matchingAttendeeName: attendee)
                // The attendee path applies its own ambiguity discipline over the whole window, so
                // `upcoming_only` is applied here rather than pushed into that query.
                if upcomingOnly {
                    events = events.filter { $0.endTime > now }
                }
            } else {
                events = try await tools.calendarEvents(
                    in: window, hour: input.hour, upcomingOnly: upcomingOnly, now: now
                )
            }
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not read the calendar."
        }
        guard !events.isEmpty else {
            // An honest empty result that also tells the model how to widen the search — without
            // this, a today-clamped miss on a "when do I next…" question reads as a definitive
            // "you have nothing", which is exactly the 2026-07-23 failure.
            let scope = Self.windowLabel(daysBack: daysBack, daysAhead: daysAhead, upcomingOnly: upcomingOnly)
            let hint = isTodayOnly
                ? " If the question is about the future, call this tool again with days_ahead (e.g. 14) and upcoming_only=true."
                : ""
            return "No matching events found on the calendar \(scope).\(hint)"
        }

        // Card-attachment selectivity (2026-07-23 live-test failure A): a FILTERED call (attendee
        // and/or hour supplied) is what the question was actually about, so those events' cards
        // are worth attaching. An UNFILTERED "what's on today" call returns the whole agenda — the
        // result TEXT below still lists every event for the model to enumerate in prose, but we
        // only attach cards when the agenda is tiny (≤2 events, effectively its own answer);
        // otherwise attaching none avoids stacking one card per event on an unrelated question.
        let attachCards = wasFiltered || events.count <= 2

        // State the searched window and the ordering outright. Without it the model cannot tell a
        // one-day result from a fortnight's, and "the first line is the soonest" is exactly the
        // fact a "when do I NEXT…" question turns on — leaving it implicit invites the model to
        // pick whichever event it read most recently.
        let scope = Self.windowLabel(daysBack: daysBack, daysAhead: daysAhead, upcomingOnly: upcomingOnly)
        var lines: [String] = ["Calendar \(scope), earliest first:"]
        for event in events {
            let localTime = RecallCardDisplay.friendlyDate(RFC3339.string(from: event.startTime)) ?? "time unavailable"
            let attendeeNames = event.attendees.compactMap(\.name)
            // Swift-computed day/tense annotation, never left to model date arithmetic (the same
            // reasoning as `RecallEngine+Tools.relativeDayAnnotation`). "already ended" is the fix
            // for the 2026-07-23 report that an 11:00 event was offered at 20:00 as what's next.
            let dayNote = Self.relativeDayNote(for: event, now: now)
            var line = "\"\(event.title)\" at \(localTime)\(dayNote) — attendees: \(attendeeNames.joined(separator: ", "))."
            if let linkedMeetingId = event.meetingId {
                await state.surface(linkedMeetingId)
                line += " This event has a recorded meeting (id \(linkedMeetingId.rawValue))."
            } else {
                line += " Scheduled only — not recorded or discussed yet."
            }
            lines.append(line)
            if attachCards {
                let payload = CalendarEventCardPayload(
                    eventId: event.id.rawValue,
                    title: event.title,
                    startTime: RFC3339.string(from: event.startTime),
                    attendeeNames: attendeeNames,
                    isLinkedToRecordedMeeting: event.meetingId != nil
                )
                await state.attach(.calendarEvent(payload))
            }
        }
        return Self.bound(lines.joined(separator: "\n"))
    }

    /// A short, honest description of the window a `calendar_events` call actually searched — used
    /// in BOTH the empty and non-empty results so "nothing found" can never be read as "nothing
    /// exists" when only today was searched.
    private static func windowLabel(daysBack: Int, daysAhead: Int, upcomingOnly: Bool) -> String {
        let base: String = switch (daysBack, daysAhead) {
        case (0, 0): "today"
        case (0, 1): "today and tomorrow"
        case (0, _): "for the next \(daysAhead) days"
        case (_, 0): "for the last \(daysBack) days through today"
        default: "from \(daysBack) day(s) ago through \(daysAhead) day(s) ahead"
        }
        return upcomingOnly ? "\(base) (not-yet-finished events only)" : base
    }

    /// " (today)" / " (tomorrow)" / " (already ended)" — real, Swift-computed, never inferred by
    /// the model. An event on today's date that has already finished gets BOTH facts, since "today"
    /// alone would still read as available.
    private static func relativeDayNote(for event: CalendarEvent, now: Date) -> String {
        let calendar = Calendar.current
        var parts: [String] = []
        if calendar.isDateInToday(event.startTime) {
            parts.append("today")
        } else if calendar.isDateInTomorrow(event.startTime) {
            parts.append("tomorrow")
        } else if calendar.isDateInYesterday(event.startTime) {
            parts.append("yesterday")
        }
        if event.endTime <= now {
            parts.append("already ended")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    // MARK: - list_recent_meetings

    private struct ListRecentMeetingsInput: Decodable {
        var limit: Int?
    }

    private func listRecentMeetings(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        let input: ListRecentMeetingsInput = Self.decode(call.argumentsJSON) ?? ListRecentMeetingsInput(limit: nil)
        let limit = min(max(input.limit ?? 10, 1), 10)

        let all: [Meeting]
        do {
            all = try await meetings.all()
        } catch {
            return "\(AgenticToolResultPrefix.toolFailed) could not list meetings."
        }
        // `meetings.all()` is already newest-first; the allowed-set filter (series scope) preserves
        // that ordering since it only removes elements.
        let filtered = allowedMeetingIds.map { allowed in all.filter { allowed.contains($0.id) } } ?? all
        guard !filtered.isEmpty else { return "No recent meetings found." }

        var lines: [String] = []
        for meeting in filtered.prefix(limit) {
            await state.surface(meeting.id)
            let date = RecallCardDisplay.friendlyDayOnly(RFC3339.string(from: meeting.createdAt)) ?? "date unavailable"
            lines.append("\(meeting.id.rawValue) / \(meeting.title) / \(date)")
        }
        return Self.bound(lines.joined(separator: "\n"))
    }

    // MARK: - Shared helpers

    private static func decode<T: Decodable>(_ json: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Truncates a tool result to `RecallBounds.maxToolResultChars` (plan §4.3) — the final
    /// per-tool-result bound applied AFTER any tool-specific bounding above.
    private static func bound(_ text: String) -> String {
        let scalars = Recall.scalars(text)
        guard scalars.count > RecallBounds.maxToolResultChars else { return text }
        let head = Recall.string(fromScalars: scalars.prefix(RecallBounds.maxToolResultChars))
        return "\(head)…"
    }
}
