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

    public init(answer: String, sources: [RecallSource]) {
        self.answer = answer
        self.sources = sources
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
