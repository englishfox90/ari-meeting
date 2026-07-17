//
//  ProtocolTests.swift
//  AriNotchTests
//
//  Cross-language conformance guarantee: the Swift Codable layer MUST decode
//  the very same shared fixtures the Rust side round-trips
//  (`frontend/src-tauri/src/notch/fixtures/*.json`), and MUST re-emit the FLAT
//  `action` wire shape.
//
//  Fixture location: we reference the shared fixtures IN PLACE (no copying) by
//  resolving a path relative to this source file via `#filePath`, then walking
//  up to the repo root. This keeps a single source of truth — if WS-A edits a
//  fixture, this test sees it immediately. (Documented in README.md.)
//
//  Module import: `@testable import ari_notch` — the SwiftPM module name for the
//  `ari-notch` executable target (hyphen → underscore). Testing an executable
//  target is supported since Swift 5.5; our floor is 5.9.
//

import XCTest
@testable import ari_notch

final class ProtocolTests: XCTestCase {

    // MARK: Fixture resolution

    /// Absolute URL of the shared fixtures directory, resolved from this file.
    ///   .../ari-notch/Tests/AriNotchTests/ProtocolTests.swift
    ///   → up 4 to repo root → frontend/src-tauri/src/notch/fixtures
    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AriNotchTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ari-notch/
            .deletingLastPathComponent() // <repo root>/
            .appendingPathComponent("frontend/src-tauri/src/notch/fixtures", isDirectory: true)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func decodeInbound(_ name: String) throws -> NotchInbound {
        try JSONDecoder().decode(NotchInbound.self, from: fixtureData(name))
    }

    private func decodeOutbound(_ name: String) throws -> NotchOutbound {
        try JSONDecoder().decode(NotchOutbound.self, from: fixtureData(name))
    }

    // MARK: - Sanity: fixtures are present where we expect them

    func testFixturesDirectoryExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.fixturesDir.path),
            "shared fixtures not found at \(Self.fixturesDir.path) — check the relative path from #filePath"
        )
    }

    // MARK: - Inbound fixtures decode to the expected case

    func testUpcomingMeetingDecodes() throws {
        let msg = try decodeInbound("upcoming_meeting.json")
        XCTAssertEqual(msg, .upcomingMeeting(UpcomingMeeting(
            eventId: "EVT-123",
            title: "Weekly 1:1 — Dana",
            startsInSeconds: 300,
            startIso: "2026-07-14T15:00:00-06:00",
            attendeeCount: 2,
            alreadyRecording: false
        )))
    }

    func testDismissUpcomingDecodes() throws {
        XCTAssertEqual(try decodeInbound("dismiss_upcoming.json"), .dismissUpcoming(eventId: "EVT-123"))
    }

    func testRecordingStateDecodes() throws {
        let msg = try decodeInbound("recording_state.json")
        XCTAssertEqual(msg, .recordingState(RecordingState(
            isRecording: true,
            isPaused: false,
            meetingName: "Weekly 1:1 — Dana",
            elapsedSeconds: 142,
            linkedEventId: "EVT-123"
        )))
    }

    func testAudioLevelDecodes() throws {
        let msg = try decodeInbound("audio_level.json")
        guard case let .audioLevel(level) = msg else {
            return XCTFail("expected .audioLevel, got \(msg)")
        }
        XCTAssertEqual(level, 0.42, accuracy: 1e-6)
    }

    func testTranscriptLineDecodes() throws {
        XCTAssertEqual(
            try decodeInbound("transcript_line.json"),
            .transcriptLine(text: "Let's start with the roadmap.", speaker: "Dana")
        )
    }

    func testConfigDecodes() throws {
        XCTAssertEqual(try decodeInbound("config.json"), .config(showTranscriptLine: true, theme: "dark"))
    }

    func testShutdownDecodes() throws {
        XCTAssertEqual(try decodeInbound("shutdown.json"), .shutdown)
    }

    // MARK: - Outbound fixtures decode to the expected case

    func testActionRecordEventDecodes() throws {
        XCTAssertEqual(try decodeOutbound("action_record_event.json"), .action(.recordEvent(eventId: "EVT-123")))
    }

    func testActionPauseDecodes() throws {
        XCTAssertEqual(try decodeOutbound("action_pause.json"), .action(.pause))
    }

    func testActionOpenAppDecodes() throws {
        XCTAssertEqual(try decodeOutbound("action_open_app.json"), .action(.openApp(route: "/meetings")))
    }

    func testReadyDecodes() throws {
        XCTAssertEqual(try decodeOutbound("ready.json"), .ready(hasNotch: true))
    }

    func testLogDecodes() throws {
        XCTAssertEqual(try decodeOutbound("log.json"), .log(level: "info", message: "sidecar started"))
    }

    // MARK: - Forward-compatibility: unknown `type` → .unknown, never throws

    func testUnknownInboundTypeDecodesToUnknown() throws {
        let data = Data(#"{"type":"totally_new_message","foo":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NotchInbound.self, from: data), .unknown)
    }

    func testUnknownOutboundTypeDecodesToUnknown() throws {
        let data = Data(#"{"type":"totally_new_message","foo":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NotchOutbound.self, from: data), .unknown)
    }

    // MARK: - Outbound encoding reproduces the FLAT wire shape

    func testActionRecordEventEncodesFlat() throws {
        let data = try JSONEncoder().encode(NotchOutbound.action(.recordEvent(eventId: "EVT-123")))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // type / action / event_id must all be TOP-LEVEL siblings.
        XCTAssertEqual(obj["type"] as? String, "action")
        XCTAssertEqual(obj["action"] as? String, "record_event")
        XCTAssertEqual(obj["event_id"] as? String, "EVT-123")
        // `action` must be a flat string, never a nested object.
        XCTAssertTrue(obj["action"] is String, "action must be a flat string discriminator, not a nested object")
        XCTAssertNil(obj["action"] as? [String: Any])
    }

    func testActionEncodingMatchesSharedFixtureSemantically() throws {
        // Encode our value, then compare to the shared fixture as parsed JSON
        // (key-order-insensitive) — the same guarantee the Rust round-trip makes.
        let encoded = try JSONEncoder().encode(NotchOutbound.action(.recordEvent(eventId: "EVT-123")))
        let mine = try JSONSerialization.jsonObject(with: encoded) as? [String: String]
        let fixtureRaw = try fixtureData("action_record_event.json")
        let theirs = try JSONSerialization.jsonObject(with: fixtureRaw) as? [String: String]
        XCTAssertEqual(mine, theirs)
    }

    func testReadyEncodesExpectedShape() throws {
        let data = try JSONEncoder().encode(NotchOutbound.ready(hasNotch: true))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "ready")
        XCTAssertEqual(obj["has_notch"] as? Bool, true)
    }
}
