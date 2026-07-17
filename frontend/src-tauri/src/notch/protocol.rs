//! Ari Notch IPC wire protocol.
//!
//! Transport is NDJSON: one JSON object per line, UTF-8. Field names are exact
//! snake_case. These types are the SHARED SOURCE OF TRUTH — a Swift `Codable`
//! layer decodes the very same `fixtures/*.json` files, so the wire shape here
//! and the fixtures must stay byte-compatible.
//!
//! Direction:
//! - [`NotchInbound`]  — Rust core → sidecar
//! - [`NotchOutbound`] — sidecar → Rust core
//!
//! Forward-compatibility (contract §4 "Unknown types are ignored"): both enums
//! carry a `#[serde(other)] Unknown` catch-all, so an unrecognized `type`
//! deserializes to `Unknown` rather than erroring.

use serde::{Deserialize, Serialize};

/// Messages sent from the Rust core down to the sidecar.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotchInbound {
    /// A calendar meeting is about to start; prompt-to-record surface.
    UpcomingMeeting {
        event_id: String,
        title: String,
        starts_in_seconds: u64,
        start_iso: String,
        attendee_count: u32,
        already_recording: bool,
    },
    /// Dismiss a previously-shown upcoming-meeting prompt.
    DismissUpcoming { event_id: String },
    /// Full recording-state snapshot for the notch UI.
    RecordingState {
        is_recording: bool,
        is_paused: bool,
        meeting_name: Option<String>,
        elapsed_seconds: u64,
        linked_event_id: Option<String>,
    },
    /// Instantaneous audio level, normalized 0.0–1.0.
    AudioLevel { level: f32 },
    /// A single freshly-transcribed line.
    TranscriptLine {
        text: String,
        speaker: Option<String>,
    },
    /// UI configuration push.
    Config {
        show_transcript_line: bool,
        theme: String,
    },
    /// Ask the sidecar to shut down cleanly.
    Shutdown,
    /// Forward-compat catch-all: any unknown `type` lands here.
    #[serde(other)]
    Unknown,
}

/// Messages sent from the sidecar up to the Rust core.
///
/// ## Action-encoding decision: `#[serde(flatten)]` over a tagged inner enum.
///
/// The wire form of an action is FLAT — e.g.
/// `{"type":"action","action":"record_event","event_id":"EVT-123"}` — with no
/// nesting. We model that by giving [`NotchOutbound`] an internally-tagged
/// `type` discriminator, and the `Action` variant flattens a second
/// internally-tagged enum [`NotchAction`] keyed on `action`. serde merges both
/// tags plus the payload fields into one flat object. The `tests` module below
/// asserts the exact flat shape (top-level `type`/`action`/`event_id`), so if
/// flatten ever "fought" the tagged inner enum the round-trip test would fail —
/// it does not; flatten is the chosen (and verified) encoding.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NotchOutbound {
    /// A user action performed in the notch UI. Flattened — see type docs.
    Action {
        #[serde(flatten)]
        action: NotchAction,
    },
    /// Sidecar handshake; reports whether a physical notch (vs. capsule) exists.
    Ready { has_notch: bool },
    /// Sidecar-side log line, surfaced through the Rust logger.
    Log { level: String, message: String },
    /// Forward-compat catch-all: any unknown `type` lands here.
    #[serde(other)]
    Unknown,
}

/// The action payload, keyed on a sibling `action` discriminator. Always
/// appears flattened into [`NotchOutbound::Action`] on the wire.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum NotchAction {
    /// Start recording the named calendar event.
    RecordEvent { event_id: String },
    /// Pause the active recording.
    Pause,
    /// Resume a paused recording.
    Resume,
    /// Stop the active recording.
    Stop,
    /// Bring the main app forward, optionally deep-linking a route.
    OpenApp { route: Option<String> },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Parse both sides to `serde_json::Value` and compare — order-insensitive.
    fn assert_semantic_eq(a: &str, b: &str) {
        let va: Value = serde_json::from_str(a).expect("lhs is valid json");
        let vb: Value = serde_json::from_str(b).expect("rhs is valid json");
        assert_eq!(va, vb, "semantic JSON mismatch\n  lhs: {a}\n  rhs: {b}");
    }

    /// Round-trip an inbound fixture: fixture → enum → json, semantically equal.
    fn roundtrip_inbound(fixture: &str) {
        let parsed: NotchInbound =
            serde_json::from_str(fixture).expect("fixture deserializes to NotchInbound");
        assert_ne!(parsed, NotchInbound::Unknown, "fixture must be a known variant");
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    /// Round-trip an outbound fixture: fixture → enum → json, semantically equal.
    fn roundtrip_outbound(fixture: &str) {
        let parsed: NotchOutbound =
            serde_json::from_str(fixture).expect("fixture deserializes to NotchOutbound");
        assert_ne!(parsed, NotchOutbound::Unknown, "fixture must be a known variant");
        let reserialized = serde_json::to_string(&parsed).expect("serializes back");
        assert_semantic_eq(fixture, &reserialized);
    }

    // ---- Inbound fixtures (Rust → sidecar) ----

    #[test]
    fn upcoming_meeting_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/upcoming_meeting.json"));
    }

    #[test]
    fn dismiss_upcoming_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/dismiss_upcoming.json"));
    }

    #[test]
    fn recording_state_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/recording_state.json"));
    }

    #[test]
    fn audio_level_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/audio_level.json"));
    }

    #[test]
    fn transcript_line_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/transcript_line.json"));
    }

    #[test]
    fn config_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/config.json"));
    }

    #[test]
    fn shutdown_roundtrips() {
        roundtrip_inbound(include_str!("fixtures/shutdown.json"));
    }

    // ---- Outbound fixtures (sidecar → Rust) ----

    #[test]
    fn action_record_event_roundtrips() {
        roundtrip_outbound(include_str!("fixtures/action_record_event.json"));
    }

    #[test]
    fn action_pause_roundtrips() {
        roundtrip_outbound(include_str!("fixtures/action_pause.json"));
    }

    #[test]
    fn action_open_app_roundtrips() {
        roundtrip_outbound(include_str!("fixtures/action_open_app.json"));
    }

    #[test]
    fn ready_roundtrips() {
        roundtrip_outbound(include_str!("fixtures/ready.json"));
    }

    #[test]
    fn log_roundtrips() {
        roundtrip_outbound(include_str!("fixtures/log.json"));
    }

    // ---- Forward-compatibility: unknown `type` → Unknown ----

    #[test]
    fn unknown_inbound_type_deserializes_to_unknown() {
        let line = r#"{"type":"totally_new_message","foo":42}"#;
        let parsed: NotchInbound = serde_json::from_str(line).expect("must not error");
        assert_eq!(parsed, NotchInbound::Unknown);
    }

    #[test]
    fn unknown_outbound_type_deserializes_to_unknown() {
        let line = r#"{"type":"totally_new_message","foo":42}"#;
        let parsed: NotchOutbound = serde_json::from_str(line).expect("must not error");
        assert_eq!(parsed, NotchOutbound::Unknown);
    }

    // ---- Flat wire-shape assertion for the flattened Action variant ----

    #[test]
    fn action_record_event_is_flat_on_the_wire() {
        let fixture = include_str!("fixtures/action_record_event.json");

        // The fixture itself must be flat.
        let v: Value = serde_json::from_str(fixture).unwrap();
        assert_eq!(v["type"], "action", "top-level type must be 'action'");
        assert_eq!(v["action"], "record_event", "sibling action discriminator");
        assert_eq!(v["event_id"], "EVT-123", "event_id at top level, not nested");
        assert!(
            v.get("action").map(|a| a.is_string()).unwrap_or(false),
            "action must be a flat string, not a nested object"
        );

        // And what WE serialize must also be flat (proves flatten worked).
        let parsed: NotchOutbound = serde_json::from_str(fixture).unwrap();
        let out = serde_json::to_value(&parsed).unwrap();
        assert_eq!(out["type"], "action");
        assert_eq!(out["action"], "record_event");
        assert_eq!(out["event_id"], "EVT-123");
        assert!(out.get("action").unwrap().is_string());
    }
}
