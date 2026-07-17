//! Wire envelope for the `ari-engine` NDJSON protocol.
//!
//! This crate defines ONLY the message envelope exchanged between the
//! headless `ari-engine` daemon and its clients (the Tauri host today, a
//! Swift shell later) over newline-delimited JSON on stdio. It has no
//! knowledge of `tauri` or `tokio` — it is pure data + (de)serialization.
//!
//! See `docs/plans/engine-extraction.md` § "Transport & message envelope"
//! for the authoritative spec this module implements byte-for-byte.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Current wire-protocol version. Present as `v` on every message.
///
/// Bumped only for a breaking change to the envelope itself (adding/removing
/// a `kind`, changing `id` semantics, etc.) — method-level evolution does
/// not require a bump.
pub const WIRE_VERSION: u64 = 1;

/// The error shape carried by a failed `response` (`kind: "response", ok: false`).
///
/// `data` is always present on the wire (as `null` when absent) — it is
/// NOT skipped when `None`, matching the spec's literal
/// `{"code": "...", "message": "...", "data": null}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WireError {
    pub code: String,
    pub message: String,
    pub data: Option<Value>,
}

impl WireError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            data: None,
        }
    }

    pub fn with_data(code: impl Into<String>, message: impl Into<String>, data: Value) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            data: Some(data),
        }
    }
}

/// The `event` field of a `kind: "stream"` message.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StreamEvent {
    Delta,
    Done,
    Error,
}

/// The single top-level envelope every NDJSON line (de)serializes to.
///
/// Internally tagged on `kind` (lowercase), so a client can read any
/// incoming line as one `Message` and match on the variant. `Response`
/// distinguishes success/failure via the `ok` bool plus which of
/// `result`/`error` is present (mirroring the spec exactly rather than
/// nesting an inner enum) — `result` is omitted from the wire when `ok` is
/// false and vice versa.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Message {
    Request {
        v: u64,
        id: u64,
        method: String,
        params: Value,
    },
    Response {
        v: u64,
        id: u64,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<WireError>,
    },
    Event {
        v: u64,
        channel: String,
        payload: Value,
    },
    Stream {
        v: u64,
        id: u64,
        event: StreamEvent,
        payload: Value,
    },
}

impl Message {
    /// Build a client→engine request.
    pub fn request(id: u64, method: impl Into<String>, params: Value) -> Message {
        Message::Request {
            v: WIRE_VERSION,
            id,
            method: method.into(),
            params,
        }
    }

    /// Build an unsolicited engine→client event (no `id`).
    pub fn event(channel: impl Into<String>, payload: Value) -> Message {
        Message::Event {
            v: WIRE_VERSION,
            channel: channel.into(),
            payload,
        }
    }

    /// Build a `stream` "delta" message tied to request `id`.
    pub fn stream_delta(id: u64, payload: Value) -> Message {
        Message::Stream {
            v: WIRE_VERSION,
            id,
            event: StreamEvent::Delta,
            payload,
        }
    }

    /// Build the terminal `stream` "done" message tied to request `id`.
    pub fn stream_done(id: u64, payload: Value) -> Message {
        Message::Stream {
            v: WIRE_VERSION,
            id,
            event: StreamEvent::Done,
            payload,
        }
    }

    /// Build the terminal `stream` "error" message tied to request `id`.
    ///
    /// Note the stream error payload on the wire is just `{code, message}`
    /// (no `data` key) — distinct from `WireError`'s response-error shape.
    pub fn stream_error(id: u64, code: impl Into<String>, message: impl Into<String>) -> Message {
        Message::Stream {
            v: WIRE_VERSION,
            id,
            event: StreamEvent::Error,
            payload: serde_json::json!({ "code": code.into(), "message": message.into() }),
        }
    }
}

/// Namespace-style constructors for `kind: "response"` messages, so call
/// sites read as `Response::ok(id, result)` / `Response::error(id, err)`.
pub struct Response;

impl Response {
    /// Build a successful response: `ok: true`, `result` present, `error` absent.
    pub fn ok(id: u64, result: Value) -> Message {
        Message::Response {
            v: WIRE_VERSION,
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    /// Build a failed response: `ok: false`, `error` present, `result` absent.
    pub fn error(id: u64, error: WireError) -> Message {
        Message::Response {
            v: WIRE_VERSION,
            id,
            ok: false,
            result: None,
            error: Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Round-trip a literal wire JSON string through deserialize -> serialize
    /// and assert the reparsed Value equals the original parsed Value
    /// (comparing as Value, not string, to avoid key-ordering flakiness).
    fn assert_roundtrip(wire_json: &str) {
        let original: Value = serde_json::from_str(wire_json).expect("literal must parse as JSON");
        let msg: Message = serde_json::from_str(wire_json).expect("must deserialize into Message");
        let reserialized = serde_json::to_value(&msg).expect("must serialize back to Value");
        assert_eq!(
            original, reserialized,
            "wire round-trip mismatch for: {wire_json}"
        );
    }

    #[test]
    fn roundtrip_request() {
        assert_roundtrip(
            r#"{"v":1,"id":482,"kind":"request","method":"recording.start","params":{"micDeviceName":"Built-in Microphone","meetingName":"Weekly Sync"}}"#,
        );
    }

    #[test]
    fn roundtrip_response_success() {
        assert_roundtrip(r#"{"v":1,"id":482,"kind":"response","ok":true,"result":{"recordingId":"b9e1..."}}"#);
    }

    #[test]
    fn roundtrip_response_failure() {
        assert_roundtrip(
            r#"{"v":1,"id":482,"kind":"response","ok":false,"error":{"code":"engine_error","message":"Microphone permission not granted","data":null}}"#,
        );
    }

    #[test]
    fn roundtrip_event() {
        assert_roundtrip(
            r#"{"v":1,"kind":"event","channel":"transcript-update","payload":{"meetingId":"b9e1...","text":"...","isFinal":false}}"#,
        );
    }

    #[test]
    fn roundtrip_stream_delta() {
        assert_roundtrip(r#"{"v":1,"id":501,"kind":"stream","event":"delta","payload":{"text":"Based on the "}}"#);
    }

    #[test]
    fn roundtrip_stream_done() {
        assert_roundtrip(
            r#"{"v":1,"id":501,"kind":"stream","event":"done","payload":{"sources":[{"meetingId":"...","snippet":"..."}]}}"#,
        );
    }

    #[test]
    fn roundtrip_stream_error() {
        assert_roundtrip(
            r#"{"v":1,"id":501,"kind":"stream","event":"error","payload":{"code":"engine_error","message":"Ollama connection refused"}}"#,
        );
    }

    #[test]
    fn failure_response_has_ok_false_and_error_with_null_data() {
        let msg = Response::error(1, WireError::new("engine_error", "boom"));
        let v = serde_json::to_value(&msg).unwrap();
        assert_eq!(v["ok"], json!(false));
        assert_eq!(v["error"]["code"], json!("engine_error"));
        assert_eq!(v["error"]["message"], json!("boom"));
        // data must be explicitly present as null, not omitted
        assert!(v.get("error").unwrap().as_object().unwrap().contains_key("data"));
        assert_eq!(v["error"]["data"], Value::Null);
        // result must be absent entirely on a failure response
        assert!(!v.as_object().unwrap().contains_key("result"));
    }

    #[test]
    fn success_response_has_no_error_key() {
        let msg = Response::ok(1, json!({"recordingId": "abc"}));
        let v = serde_json::to_value(&msg).unwrap();
        assert_eq!(v["ok"], json!(true));
        assert!(!v.as_object().unwrap().contains_key("error"));
    }

    #[test]
    fn event_has_no_id_key_on_wire() {
        let msg = Message::event("transcript-update", json!({"text": "hi"}));
        let v = serde_json::to_value(&msg).unwrap();
        assert!(
            !v.as_object().unwrap().contains_key("id"),
            "event must not carry an id: {v}"
        );
    }

    #[test]
    fn unknown_kind_fails_cleanly_not_panics() {
        let bad = r#"{"v":1,"kind":"bogus","id":1}"#;
        let result: Result<Message, _> = serde_json::from_str(bad);
        assert!(result.is_err(), "unknown kind must fail to deserialize, not panic");
    }

    #[test]
    fn missing_kind_fails_cleanly() {
        let bad = r#"{"v":1,"id":1}"#;
        let result: Result<Message, _> = serde_json::from_str(bad);
        assert!(result.is_err());
    }

    #[test]
    fn constructors_produce_expected_shapes() {
        let req = Message::request(482, "recording.start", json!({"micDeviceName": "Built-in Microphone"}));
        match &req {
            Message::Request { v, id, method, .. } => {
                assert_eq!(*v, WIRE_VERSION);
                assert_eq!(*id, 482);
                assert_eq!(method, "recording.start");
            }
            _ => panic!("expected Request variant"),
        }

        let done = Message::stream_done(501, json!({"sources": []}));
        match &done {
            Message::Stream { event, id, .. } => {
                assert_eq!(*event, StreamEvent::Done);
                assert_eq!(*id, 501);
            }
            _ => panic!("expected Stream variant"),
        }

        let serr = Message::stream_error(501, "engine_error", "Ollama connection refused");
        let v = serde_json::to_value(&serr).unwrap();
        assert_eq!(v["event"], json!("error"));
        assert_eq!(v["payload"]["code"], json!("engine_error"));
        // stream error payload has no `data` key per spec
        assert!(!v["payload"].as_object().unwrap().contains_key("data"));
    }
}
