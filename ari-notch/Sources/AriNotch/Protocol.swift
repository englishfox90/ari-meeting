//
//  Protocol.swift
//  ari-notch
//
//  Swift `Codable` mirror of the Ari Notch IPC wire protocol.
//
//  SINGLE SOURCE OF TRUTH lives on the Rust side:
//  `frontend/src-tauri/src/notch/protocol.rs` + `frontend/src-tauri/src/notch/fixtures/*.json`.
//  These types MUST decode those exact fixture files byte-for-byte, and the
//  outbound encoder MUST reproduce the FLAT `action` wire shape
//  (`{"type":"action","action":"record_event","event_id":"EVT-123"}` — the
//  `action` discriminator and its payload are siblings of `type`, never nested).
//
//  Field names are exact snake_case; we spell every CodingKey explicitly rather
//  than relying on a key strategy so the mapping is auditable against the Rust
//  `#[serde(rename_all = "snake_case")]` derive.
//
//  Forward-compatibility: any unrecognized `type` decodes to `.unknown` and
//  never throws — mirroring the Rust `#[serde(other)] Unknown` catch-all.
//

import Foundation

// MARK: - Inbound (Rust core → sidecar)

/// A calendar meeting about to start; the prompt-to-record surface.
struct UpcomingMeeting: Equatable {
    let eventId: String
    let title: String
    let startsInSeconds: UInt64
    let startIso: String
    let attendeeCount: UInt32
    let alreadyRecording: Bool
}

/// Full recording-state snapshot for the notch UI.
struct RecordingState: Equatable {
    let isRecording: Bool
    let isPaused: Bool
    let meetingName: String?
    let elapsedSeconds: UInt64
    let linkedEventId: String?
}

/// Messages sent from the Rust core down to the sidecar.
enum NotchInbound: Equatable {
    case upcomingMeeting(UpcomingMeeting)
    case dismissUpcoming(eventId: String)
    case recordingState(RecordingState)
    case audioLevel(level: Double)
    case transcriptLine(text: String, speaker: String?)
    case config(showTranscriptLine: Bool, theme: String)
    case shutdown
    /// Forward-compat catch-all: any unknown `type` lands here.
    case unknown
}

// MARK: - Outbound (sidecar → Rust core)

/// The action payload, keyed on a sibling `action` discriminator. Always
/// appears FLATTENED into `NotchOutbound.action` on the wire.
enum NotchAction: Equatable {
    case recordEvent(eventId: String)
    case pause
    case resume
    case stop
    case openApp(route: String?)
}

/// Messages sent from the sidecar up to the Rust core.
enum NotchOutbound: Equatable {
    case action(NotchAction)
    case ready(hasNotch: Bool)
    case log(level: String, message: String)
    /// Forward-compat catch-all: any unknown `type` lands here.
    case unknown
}

// MARK: - Coding keys (exact snake_case, matching protocol.rs)

/// One flat key-space covering every field across every message. Because the
/// wire form of an action is flat, the outbound encoder writes `type`, `action`
/// and the payload fields into a single keyed container using these keys.
private enum WireKey: String, CodingKey {
    case type
    case action
    // upcoming_meeting
    case eventId = "event_id"
    case title
    case startsInSeconds = "starts_in_seconds"
    case startIso = "start_iso"
    case attendeeCount = "attendee_count"
    case alreadyRecording = "already_recording"
    // recording_state
    case isRecording = "is_recording"
    case isPaused = "is_paused"
    case meetingName = "meeting_name"
    case elapsedSeconds = "elapsed_seconds"
    case linkedEventId = "linked_event_id"
    // audio_level
    case level
    // transcript_line
    case text
    case speaker
    // config
    case showTranscriptLine = "show_transcript_line"
    case theme
    // outbound: ready / log / open_app
    case hasNotch = "has_notch"
    case message
    case route
}

// MARK: - Inbound decoding

extension NotchInbound: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        // An unknown or absent `type` must degrade to `.unknown`, never throw.
        guard let type = try? c.decode(String.self, forKey: .type) else {
            self = .unknown
            return
        }
        switch type {
        case "upcoming_meeting":
            self = .upcomingMeeting(UpcomingMeeting(
                eventId: try c.decode(String.self, forKey: .eventId),
                title: try c.decode(String.self, forKey: .title),
                startsInSeconds: try c.decode(UInt64.self, forKey: .startsInSeconds),
                startIso: try c.decode(String.self, forKey: .startIso),
                attendeeCount: try c.decode(UInt32.self, forKey: .attendeeCount),
                alreadyRecording: try c.decode(Bool.self, forKey: .alreadyRecording)
            ))
        case "dismiss_upcoming":
            self = .dismissUpcoming(eventId: try c.decode(String.self, forKey: .eventId))
        case "recording_state":
            self = .recordingState(RecordingState(
                isRecording: try c.decode(Bool.self, forKey: .isRecording),
                isPaused: try c.decode(Bool.self, forKey: .isPaused),
                meetingName: try c.decodeIfPresent(String.self, forKey: .meetingName),
                elapsedSeconds: try c.decode(UInt64.self, forKey: .elapsedSeconds),
                linkedEventId: try c.decodeIfPresent(String.self, forKey: .linkedEventId)
            ))
        case "audio_level":
            self = .audioLevel(level: try c.decode(Double.self, forKey: .level))
        case "transcript_line":
            self = .transcriptLine(
                text: try c.decode(String.self, forKey: .text),
                speaker: try c.decodeIfPresent(String.self, forKey: .speaker)
            )
        case "config":
            self = .config(
                showTranscriptLine: try c.decode(Bool.self, forKey: .showTranscriptLine),
                theme: try c.decode(String.self, forKey: .theme)
            )
        case "shutdown":
            self = .shutdown
        default:
            self = .unknown
        }
    }
}

// MARK: - Inbound encoding
//
// Not used on the hot path (the sidecar only RECEIVES inbound), but implemented
// so ProtocolTests can round-trip fixtures symmetrically the way the Rust tests
// do. Reproduces the exact snake_case wire shape.

extension NotchInbound: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case let .upcomingMeeting(m):
            try c.encode("upcoming_meeting", forKey: .type)
            try c.encode(m.eventId, forKey: .eventId)
            try c.encode(m.title, forKey: .title)
            try c.encode(m.startsInSeconds, forKey: .startsInSeconds)
            try c.encode(m.startIso, forKey: .startIso)
            try c.encode(m.attendeeCount, forKey: .attendeeCount)
            try c.encode(m.alreadyRecording, forKey: .alreadyRecording)
        case let .dismissUpcoming(eventId):
            try c.encode("dismiss_upcoming", forKey: .type)
            try c.encode(eventId, forKey: .eventId)
        case let .recordingState(s):
            try c.encode("recording_state", forKey: .type)
            try c.encode(s.isRecording, forKey: .isRecording)
            try c.encode(s.isPaused, forKey: .isPaused)
            try c.encode(s.meetingName, forKey: .meetingName) // serde emits null for None
            try c.encode(s.elapsedSeconds, forKey: .elapsedSeconds)
            try c.encode(s.linkedEventId, forKey: .linkedEventId)
        case let .audioLevel(level):
            try c.encode("audio_level", forKey: .type)
            try c.encode(level, forKey: .level)
        case let .transcriptLine(text, speaker):
            try c.encode("transcript_line", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(speaker, forKey: .speaker) // serde emits null for None
        case let .config(showTranscriptLine, theme):
            try c.encode("config", forKey: .type)
            try c.encode(showTranscriptLine, forKey: .showTranscriptLine)
            try c.encode(theme, forKey: .theme)
        case .shutdown:
            try c.encode("shutdown", forKey: .type)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Outbound encoding (the load-bearing FLAT shape)

extension NotchOutbound: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case let .action(action):
            // FLAT: type + action + payload fields are all siblings.
            try c.encode("action", forKey: .type)
            switch action {
            case let .recordEvent(eventId):
                try c.encode("record_event", forKey: .action)
                try c.encode(eventId, forKey: .eventId)
            case .pause:
                try c.encode("pause", forKey: .action)
            case .resume:
                try c.encode("resume", forKey: .action)
            case .stop:
                try c.encode("stop", forKey: .action)
            case let .openApp(route):
                try c.encode("open_app", forKey: .action)
                // Rust `Option<String>` with no skip → null when None; Rust
                // decode accepts both null and absent, so encodeIfPresent is safe.
                try c.encodeIfPresent(route, forKey: .route)
            }
        case let .ready(hasNotch):
            try c.encode("ready", forKey: .type)
            try c.encode(hasNotch, forKey: .hasNotch)
        case let .log(level, message):
            try c.encode("log", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encode(message, forKey: .message)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Outbound decoding
//
// Implemented so ProtocolTests can decode the outbound fixtures (action_*,
// ready, log) and assert the expected case. The sidecar itself only SENDS
// outbound, so this is test-facing, but it keeps the conformance symmetric.

extension NotchOutbound: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        guard let type = try? c.decode(String.self, forKey: .type) else {
            self = .unknown
            return
        }
        switch type {
        case "action":
            guard let action = try? c.decode(String.self, forKey: .action) else {
                self = .unknown
                return
            }
            switch action {
            case "record_event":
                self = .action(.recordEvent(eventId: try c.decode(String.self, forKey: .eventId)))
            case "pause":
                self = .action(.pause)
            case "resume":
                self = .action(.resume)
            case "stop":
                self = .action(.stop)
            case "open_app":
                self = .action(.openApp(route: try c.decodeIfPresent(String.self, forKey: .route)))
            default:
                self = .unknown
            }
        case "ready":
            self = .ready(hasNotch: try c.decode(Bool.self, forKey: .hasNotch))
        case "log":
            self = .log(
                level: try c.decode(String.self, forKey: .level),
                message: try c.decode(String.self, forKey: .message)
            )
        default:
            self = .unknown
        }
    }
}
