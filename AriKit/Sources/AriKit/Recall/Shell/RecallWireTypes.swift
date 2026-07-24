//
//  RecallWireTypes.swift — the recall wire value types (plan §2.2, ← shell.rs / models.rs).
//
//  These mirror the Rust `serde` DTOs the frontend renders. Unlike the four snake_case
//  database-origin `Models` types (arikit-models.md §7.7), the Rust recall DTOs already carry
//  explicit `#[serde(rename = "matchContext"/"meetingDate")]` + `#[serde(default)] speakers`, so
//  this camelCase-native Swift shape decodes the frontend wire DIRECTLY — the Store's
//  snake→camel adapter must NOT be applied to recall sources.
//
//  `meetingId`/`id` stay bare `String` (not typed IDs) to match the Rust serde surface exactly:
//  these cross the frontend boundary. Typed IDs are used at the repository/orchestrator seam.
//
import Foundation

/// A source the local recall command actually supplied to the local model (← `LocalRecallSource`,
/// shell.rs:57). The UI renders this independently from the answer text; the model is never
/// trusted to invent citations.
public struct RecallSource: Codable, Hashable, Sendable {
    public var meetingId: String
    public var title: String
    public var matchContext: String
    public var timestamp: String
    public var meetingDate: String?
    public var summary: String?
    /// Display names of people associated with this source (identified speakers / attendees).
    /// Empty until Phase 2 context assembly (Slice 7) populates it — the UI renders tags only when
    /// present (No-Fake-State). Decodes to `[]` when the wire key is absent (Rust `#[serde(default)]`).
    public var speakers: [String]

    public init(
        meetingId: String,
        title: String,
        matchContext: String,
        timestamp: String,
        meetingDate: String? = nil,
        summary: String? = nil,
        speakers: [String] = []
    ) {
        self.meetingId = meetingId
        self.title = title
        self.matchContext = matchContext
        self.timestamp = timestamp
        self.meetingDate = meetingDate
        self.summary = summary
        self.speakers = speakers
    }
}

extension RecallSource {
    private enum CodingKeys: String, CodingKey {
        case meetingId, title, matchContext, timestamp, meetingDate, summary, speakers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingId = try container.decode(String.self, forKey: .meetingId)
        title = try container.decode(String.self, forKey: .title)
        matchContext = try container.decode(String.self, forKey: .matchContext)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        meetingDate = try container.decodeIfPresent(String.self, forKey: .meetingDate)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        // `#[serde(default)]` parity: a missing `speakers` key decodes to an empty array.
        speakers = try container.decodeIfPresent([String].self, forKey: .speakers) ?? []
    }
}

/// The recall answer + its separately-computed sources (← `LocalRecallResponse`, shell.rs:74).
public struct RecallResponse: Codable, Hashable, Sendable {
    public var answer: String
    public var sources: [RecallSource]
    /// A deterministically-resolved entity card (plan §5.1, `ask-meetings-tools-and-cards.md`),
    /// additive to the wire shape. `nil` unless Slice B's global-scope entity resolution found
    /// EXACTLY ONE real, unambiguous row — never a partial match, never a placeholder
    /// (No-Fake-State). Kept as wire/persistence BACK-COMPAT (plan §5.4,
    /// `ask-meetings-agentic-tools.md`) — always equal to `cards.first`.
    public var card: RecallCardPayload?
    /// The full set of resolved cards (plan §5.4) — the tool-first agentic path can resolve MORE
    /// THAN ONE entity per ask (e.g. a person + today's calendar event). Decodes to `[]` when the
    /// wire key is absent (mirrors `RecallSource.speakers`'s default-on-missing-key pattern), and
    /// derives from `card` when only the legacy singular field is present (back-compat with
    /// anything persisted before this field existed).
    public var cards: [RecallCardPayload]

    public init(
        answer: String,
        sources: [RecallSource],
        card: RecallCardPayload? = nil,
        cards: [RecallCardPayload]? = nil
    ) {
        self.answer = answer
        self.sources = sources
        let resolvedCards = cards ?? (card.map { [$0] } ?? [])
        self.cards = resolvedCards
        self.card = card ?? resolvedCards.first
    }
}

extension RecallResponse {
    private enum CodingKeys: String, CodingKey {
        case answer, sources, card, cards
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = try container.decode(String.self, forKey: .answer)
        sources = try container.decode([RecallSource].self, forKey: .sources)
        let decodedCard = try container.decodeIfPresent(RecallCardPayload.self, forKey: .card)
        // `#[serde(default)]`-style parity: a missing `cards` key falls back to `[decodedCard]`
        // (or `[]` when there's no legacy `card` either) — never a fabricated placeholder.
        cards = try container.decodeIfPresent([RecallCardPayload].self, forKey: .cards)
            ?? (decodedCard.map { [$0] } ?? [])
        card = decodedCard ?? cards.first
    }
}

// MARK: - Inline entity cards (plan §5.1, Slice C wire contract — populated by Slice B, rendered

// by a later Slice C)

/// A deterministically-resolved entity, ready to render as an inline card in the Ask chat (Slice C,
/// out of scope for this change — only the wire contract + real data population land here).
public enum RecallCardPayload: Codable, Hashable, Sendable {
    case meeting(MeetingCardPayload)
    case person(PersonCardPayload)
    case series(SeriesCardPayload)
    case calendarEvent(CalendarEventCardPayload)
}

public struct MeetingCardPayload: Codable, Hashable, Sendable {
    public var meetingId: String
    public var title: String
    /// RFC3339, same convention as `RecallSource.meetingDate`.
    public var meetingDate: String?
    /// Real, not fabricated — drives whether a future card UI shows a summary snippet.
    public var hasSummary: Bool

    public init(meetingId: String, title: String, meetingDate: String? = nil, hasSummary: Bool) {
        self.meetingId = meetingId
        self.title = title
        self.meetingDate = meetingDate
        self.hasSummary = hasSummary
    }
}

public struct PersonCardPayload: Codable, Hashable, Sendable {
    public var personId: String
    public var displayName: String
    public var role: String?
    public var organization: String?
    /// From `RecallTools.meetings(withPerson:).first`, real or `nil` — never estimated.
    public var lastMeetingDate: String?
    /// Real count from the same query that produced `lastMeetingDate` — never estimated.
    public var meetingCount: Int

    public init(
        personId: String,
        displayName: String,
        role: String? = nil,
        organization: String? = nil,
        lastMeetingDate: String? = nil,
        meetingCount: Int
    ) {
        self.personId = personId
        self.displayName = displayName
        self.role = role
        self.organization = organization
        self.lastMeetingDate = lastMeetingDate
        self.meetingCount = meetingCount
    }
}

/// A real, SCHEDULED calendar event (never a recorded/saved meeting — those are `MeetingCardPayload`,
/// a deliberately separate case). Populated only from `CalendarEventRepository`/`RecallTools.
/// calendarEventsToday(matchingAttendeeName:)` — a real DB row, never a placeholder (No-Fake-State).
/// A calendar entry means "scheduled," never "happened" or "discussed" — card UI (Slice C follow-up,
/// out of scope here) must render this distinctly from a recorded-meeting card.
public struct CalendarEventCardPayload: Codable, Hashable, Sendable {
    public var eventId: String
    public var title: String
    /// RFC3339, same convention as the other card payloads.
    public var startTime: String
    public var attendeeNames: [String]
    /// Real, not fabricated — `true` only when this calendar event is actually linked to a saved
    /// `Meeting` (a non-nil `meetingId` on the `CalendarEvent` row). Drives whether card UI offers
    /// to open the recorded meeting vs. just showing it's scheduled.
    public var isLinkedToRecordedMeeting: Bool

    public init(
        eventId: String,
        title: String,
        startTime: String,
        attendeeNames: [String],
        isLinkedToRecordedMeeting: Bool
    ) {
        self.eventId = eventId
        self.title = title
        self.startTime = startTime
        self.attendeeNames = attendeeNames
        self.isLinkedToRecordedMeeting = isLinkedToRecordedMeeting
    }
}

public struct SeriesCardPayload: Codable, Hashable, Sendable {
    public var seriesId: String
    public var title: String
    public var meetingCount: Int
    public var lastMeetingDate: String?

    public init(seriesId: String, title: String, meetingCount: Int, lastMeetingDate: String? = nil) {
        self.seriesId = seriesId
        self.title = title
        self.meetingCount = meetingCount
        self.lastMeetingDate = lastMeetingDate
    }
}

/// One prior conversation turn (← `LocalRecallTurn`, shell.rs:80). `role` is validated by the
/// shell; only `user`/`assistant` are accepted (a `system` role is rejected — never trusted).
public struct RecallTurn: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// The retrieval-boundary type (← `TranscriptSearchResult`, models.rs:12). The shell consumes it;
/// the (later) search layer produces it. `id` is the meeting id — repeated across a meeting's
/// chunks; the shell dedups + caps.
public struct TranscriptSearchResult: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var matchContext: String
    public var timestamp: String
    public var meetingDate: String?
    public var summary: String?

    public init(
        id: String,
        title: String,
        matchContext: String,
        timestamp: String,
        meetingDate: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.matchContext = matchContext
        self.timestamp = timestamp
        self.meetingDate = meetingDate
        self.summary = summary
    }
}
