//
//  RecordingHUDTests.swift
//  AriNotchTests
//
//  WS-C acceptance tests for the Recording HUD. We drive the shared @Observable
//  `NotchModel` with the SAME shared fixtures the protocol conformance uses
//  (`frontend/src-tauri/src/notch/fixtures/*.json`) and assert the state the HUD
//  binds to, then assert each control emits EXACTLY the right `NotchAction`
//  (captured by a mock emitter, and verified to encode to the flat wire shape),
//  and finally assert the mm:ss formatter.
//
//  The view itself is not snapshot-rendered (no interactive display in CI); we
//  test its bindings + extracted action/formatter logic, which is where all the
//  WS-C behavior lives.
//

import XCTest
@testable import ari_notch

// MARK: - Capturing mock emitter

/// Records every emitted action so tests can assert the exact outbound value.
final class MockActionEmitter: NotchActionEmitter {
    private(set) var emitted: [NotchAction] = []
    func emit(_ action: NotchAction) {
        emitted.append(action)
    }
}

@MainActor
final class RecordingHUDTests: XCTestCase {

    // MARK: Fixture resolution (mirrors ProtocolTests: reference shared fixtures in place)

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AriNotchTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ari-notch/
            .deletingLastPathComponent() // <repo root>/
            .appendingPathComponent("frontend/src-tauri/src/notch/fixtures", isDirectory: true)
    }

    private func decodeInbound(_ name: String) throws -> NotchInbound {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return try JSONDecoder().decode(NotchInbound.self, from: Data(contentsOf: url))
    }

    // MARK: - Model bindings the HUD reads (fed from shared fixtures)

    func testRecordingStateFixtureDrivesModelBindings() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("recording_state.json"))

        XCTAssertTrue(model.isRecording)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.meetingName, "Weekly 1:1 — Dana")
        XCTAssertEqual(model.elapsedSeconds, 142)
        XCTAssertEqual(model.linkedEventId, "EVT-123")
    }

    func testAudioLevelFixtureDrivesBar() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("audio_level.json"))
        XCTAssertEqual(model.audioLevel, 0.42, accuracy: 1e-6)
    }

    func testTranscriptLineFixtureDrivesOptionalLine() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("config.json"))            // show_transcript_line = true
        model.apply(try decodeInbound("transcript_line.json"))
        XCTAssertTrue(model.showTranscriptLine)
        XCTAssertEqual(model.latestTranscript?.text, "Let's start with the roadmap.")
        XCTAssertEqual(model.latestTranscript?.speaker, "Dana")
    }

    /// A scripted sequence (state → audio → transcript) folds into the exact
    /// terminal state the HUD binds to.
    func testScriptedSequenceFoldsToExpectedState() throws {
        let model = NotchModel()
        for fixture in ["config.json", "recording_state.json", "audio_level.json", "transcript_line.json"] {
            model.apply(try decodeInbound(fixture))
        }
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(model.elapsedSeconds, 142)
        XCTAssertEqual(model.audioLevel, 0.42, accuracy: 1e-6)
        XCTAssertEqual(model.latestTranscript?.text, "Let's start with the roadmap.")
    }

    // MARK: - Controls emit exactly the right action

    func testPauseButtonEmitsPauseWhenRecording() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("recording_state.json")) // is_paused = false
        let mock = MockActionEmitter()
        let hud = RecordingHUDView(model: model, emitter: mock)

        hud.handlePauseResume()

        XCTAssertEqual(mock.emitted, [.pause])
    }

    func testResumeButtonEmitsResumeWhenPaused() {
        let model = NotchModel()
        model.isRecording = true
        model.isPaused = true
        let mock = MockActionEmitter()
        let hud = RecordingHUDView(model: model, emitter: mock)

        hud.handlePauseResume()

        XCTAssertEqual(mock.emitted, [.resume])
    }

    func testStopButtonEmitsStop() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("recording_state.json"))
        let mock = MockActionEmitter()
        let hud = RecordingHUDView(model: model, emitter: mock)

        hud.handleStop()

        XCTAssertEqual(mock.emitted, [.stop])
    }

    func testOpenAppButtonEmitsOpenAppWithNoRoute() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("recording_state.json"))
        let mock = MockActionEmitter()
        let hud = RecordingHUDView(model: model, emitter: mock)

        hud.handleOpenApp()

        XCTAssertEqual(mock.emitted, [.openApp(route: nil)])
    }

    /// The captured action must serialize to the FLAT wire shape the Rust side
    /// expects: `{"type":"action","action":"stop"}`.
    func testEmittedStopEncodesToFlatWireShape() {
        let mock = MockActionEmitter()
        mock.emit(.stop)
        let action = try! XCTUnwrap(mock.emitted.first)

        let data = try! JSONEncoder().encode(NotchOutbound.action(action))
        let obj = try! JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(obj, ["type": "action", "action": "stop"])
    }

    // MARK: - Local elapsed clock

    func testFormatElapsed() {
        XCTAssertEqual(RecordingHUDView.formatElapsed(0), "00:00")
        XCTAssertEqual(RecordingHUDView.formatElapsed(125), "02:05")
        XCTAssertEqual(RecordingHUDView.formatElapsed(3600), "60:00")
        XCTAssertEqual(RecordingHUDView.formatElapsed(9), "00:09")
        XCTAssertEqual(RecordingHUDView.formatElapsed(599), "09:59")
    }

    /// Not-recording: the clock reports the authoritative base and invents no
    /// forward time even as wall-clock advances (No-Fake-State).
    func testDisplayedSecondsDoesNotAdvanceWhenNotRecording() {
        let model = NotchModel()
        model.isRecording = false
        model.elapsedSeconds = 30
        let hud = RecordingHUDView(model: model, emitter: MockActionEmitter())
        // resync() runs onAppear in the live view; base defaults to 0 here, and
        // because we're not recording the clock must not fabricate elapsed time.
        let future = Date().addingTimeInterval(120)
        XCTAssertEqual(hud.displayedSeconds(at: future), 0)
    }
}
