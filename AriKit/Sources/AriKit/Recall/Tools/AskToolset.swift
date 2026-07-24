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
    public func attach(_ card: RecallCardPayload) {
        guard !cards.contains(card) else { return }
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

    public init(
        tools: RecallTools,
        hybridSearch: HybridSearch,
        meetings: MeetingRepository,
        allowedMeetingIds: Set<MeetingID>? = nil
    ) {
        self.tools = tools
        self.hybridSearch = hybridSearch
        self.meetings = meetings
        self.allowedMeetingIds = allowedMeetingIds
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
                name: "todays_events",
                description: "List today's calendar events, optionally filtered by hour (0-23, e.g. 18 for 6pm) or an attendee name/email. A calendar event means something is SCHEDULED, never that it was recorded or discussed.",
                parametersJSONSchema: #"{"type":"object","properties":{"hour":{"type":"integer"},"attendee":{"type":"string"}}}"#
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
        case "todays_events": "Checking today's calendar"
        case "list_recent_meetings": "Listing recent meetings"
        default: "Running \(toolName)"
        }
    }

    // MARK: - Dispatch (← `AgenticToolDispatch`, the frozen Slice-0 contract)

    /// Executes one requested tool call. Never throws — an unknown tool, invalid arguments, a
    /// budget exhaustion, or a repository failure all return an honest string result so the model
    /// can recover (plan §4.3).
    public func dispatch(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard await state.beginIteration() else {
            return "Tool budget exhausted. Answer now from the information you already have."
        }
        switch call.name {
        case "search_transcripts":
            return await searchTranscripts(call, state: state)
        case "find_person":
            return await findPerson(call, state: state)
        case "find_meeting":
            return await findMeeting(call, state: state)
        case "get_meeting_summary":
            return await getMeetingSummary(call, state: state)
        case "todays_events":
            return await todaysEvents(call, state: state)
        case "list_recent_meetings":
            return await listRecentMeetings(call, state: state)
        default:
            return "Unknown tool: \(call.name)"
        }
    }

    // MARK: - search_transcripts

    private struct SearchTranscriptsInput: Decodable {
        var query: String
        var limit: Int?
    }

    private func searchTranscripts(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        guard let input: SearchTranscriptsInput = Self.decode(call.argumentsJSON) else {
            return "Invalid arguments: expected {\"query\": string}."
        }
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Invalid arguments: \"query\" must not be empty." }
        let limit = min(max(input.limit ?? 8, 1), 8)

        let results: [TranscriptSearchResult]
        do {
            results = if let allowedMeetingIds {
                try await hybridSearch.globalSearchScoped(query, allowedMeetingIds: allowedMeetingIds)
            } else {
                try await hybridSearch.globalSearch(query)
            }
        } catch {
            return "Tool failed: could not search transcripts."
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
            lines.append("[S\(index)] \(result.title) (\(dateLabel)) — \(excerpt)")
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
            return "Invalid arguments: expected {\"name\": string}."
        }
        let person: Person?
        do {
            person = try await tools.findPerson(nameContaining: input.name)
        } catch {
            return "Tool failed: could not look up that person."
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
            return "Invalid arguments: expected {\"title_or_topic\": string}."
        }
        let meeting: Meeting?
        do {
            meeting = try await tools.findMeeting(titleContaining: input.titleOrTopic)
        } catch {
            return "Tool failed: could not look up that meeting."
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
            return "Invalid arguments: expected {\"meeting_id\": string}."
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
            return "Tool failed: could not read that meeting's summary."
        }
        guard let summary else {
            return "That meeting has no saved summary yet."
        }
        return Self.bound(summary)
    }

    // MARK: - todays_events

    private struct TodaysEventsInput: Decodable {
        var hour: Int?
        var attendee: String?
    }

    private func todaysEvents(_ call: AgenticToolCall, state: ToolTurnState) async -> String {
        let input: TodaysEventsInput = Self.decode(call.argumentsJSON) ?? TodaysEventsInput(hour: nil, attendee: nil)
        if let hour = input.hour, !(0 ... 23).contains(hour) {
            return "Invalid arguments: \"hour\" must be 0-23."
        }
        let events: [CalendarEvent]
        do {
            let attendee = input.attendee?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let attendee, !attendee.isEmpty {
                events = try await tools.calendarEventsToday(matchingAttendeeName: attendee)
            } else {
                events = try await tools.calendarEvents(today: input.hour)
            }
        } catch {
            return "Tool failed: could not read the calendar."
        }
        guard !events.isEmpty else { return "No matching events found on today's calendar." }

        var lines: [String] = []
        for event in events {
            let localTime = RecallCardDisplay.friendlyDate(RFC3339.string(from: event.startTime)) ?? "time unavailable"
            let attendeeNames = event.attendees.compactMap(\.name)
            var line = "\"\(event.title)\" at \(localTime) — attendees: \(attendeeNames.joined(separator: ", "))."
            if let linkedMeetingId = event.meetingId {
                await state.surface(linkedMeetingId)
                line += " This event has a recorded meeting (id \(linkedMeetingId.rawValue))."
            } else {
                line += " Scheduled only — not recorded or discussed yet."
            }
            lines.append(line)
            let payload = CalendarEventCardPayload(
                eventId: event.id.rawValue,
                title: event.title,
                startTime: RFC3339.string(from: event.startTime),
                attendeeNames: attendeeNames,
                isLinkedToRecordedMeeting: event.meetingId != nil
            )
            await state.attach(.calendarEvent(payload))
        }
        return Self.bound(lines.joined(separator: "\n"))
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
            return "Tool failed: could not list meetings."
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
