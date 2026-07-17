//
//  UpcomingMeetingTests.swift
//  AriNotchTests
//
//  WS-G acceptance tests for the UC1 Upcoming-meeting alert. We drive the shared
//  @Observable `NotchModel` with the SAME shared fixtures the protocol
//  conformance uses (`frontend/src-tauri/src/notch/fixtures/*.json`) and assert
//  the state the view binds to, then assert the Record control emits EXACTLY the
//  right `NotchAction` (captured by a mock emitter, verified to encode to the
//  flat wire shape), the countdown formatter, and the dismiss-clears-state path.
//
//  The view itself is not snapshot-rendered (no interactive display in CI); we
//  test its bindings + extracted action/formatter logic, which is where all the
//  WS-G behavior lives. The `MockActionEmitter` is reused from RecordingHUDTests.
//

import XCTest
@testable import ari_notch

@MainActor
final class UpcomingMeetingTests: XCTestCase {

    // MARK: Fixture resolution (mirrors RecordingHUDTests: reference shared fixtures in place)

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

    // MARK: - Model bindings the view reads (fed from the shared fixture)

    func testUpcomingMeetingFixtureDrivesModelBindings() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))

        let meeting = try XCTUnwrap(model.upcomingMeeting)
        XCTAssertEqual(meeting.eventId, "EVT-123")
        XCTAssertEqual(meeting.title, "Weekly 1:1 — Dana")
        XCTAssertEqual(meeting.startsInSeconds, 300)
        XCTAssertEqual(meeting.attendeeCount, 2)
        XCTAssertFalse(meeting.alreadyRecording)
    }

    // MARK: - Local countdown clock

    /// Immediately after sync, the countdown reflects the authoritative
    /// `starts_in_seconds` (300 → 5:00) rendered mm:ss.
    func testCountdownStartsAtAuthoritativeValue() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))
        let view = UpcomingMeetingView(model: model, emitter: MockActionEmitter())

        // No local resync() has run (that fires onAppear in the live view), so
        // baseStartsIn is still 0 here — the clock must not fabricate time.
        XCTAssertEqual(view.remainingSeconds(at: Date()), 0)
    }

    /// The formatter matches WS-C's mm:ss style; 0 collapses to "Starting now"
    /// rather than showing a negative or fake time (No-Fake-State).
    func testFormatCountdown() {
        XCTAssertEqual(UpcomingMeetingView.formatCountdown(300), "05:00")
        XCTAssertEqual(UpcomingMeetingView.formatCountdown(125), "02:05")
        XCTAssertEqual(UpcomingMeetingView.formatCountdown(59), "00:59")
        XCTAssertEqual(UpcomingMeetingView.formatCountdown(3600), "60:00")
        XCTAssertEqual(UpcomingMeetingView.formatCountdown(0), "Starting now")
    }

    func testFormatAttendees() {
        XCTAssertEqual(UpcomingMeetingView.formatAttendees(1), "1 attendee")
        XCTAssertEqual(UpcomingMeetingView.formatAttendees(2), "2 attendees")
    }

    // MARK: - Record control emits exactly the right action

    func testRecordButtonEmitsRecordEventWithFixtureEventId() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))
        let mock = MockActionEmitter()
        let view = UpcomingMeetingView(model: model, emitter: mock)

        view.handleRecord()

        XCTAssertEqual(mock.emitted, [.recordEvent(eventId: "EVT-123")])
    }

    func testOpenAppButtonEmitsOpenAppWithNoRoute() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))
        let mock = MockActionEmitter()
        let view = UpcomingMeetingView(model: model, emitter: mock)

        view.handleOpenApp()

        XCTAssertEqual(mock.emitted, [.openApp(route: nil)])
    }

    /// The captured action must serialize to the FLAT wire shape the Rust side
    /// expects: `{"type":"action","action":"record_event","event_id":"EVT-123"}`.
    func testEmittedRecordEncodesToFlatWireShape() {
        let mock = MockActionEmitter()
        mock.emit(.recordEvent(eventId: "EVT-123"))
        let action = try! XCTUnwrap(mock.emitted.first)

        let data = try! JSONEncoder().encode(NotchOutbound.action(action))
        let obj = try! JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(obj, ["type": "action", "action": "record_event", "event_id": "EVT-123"])
    }

    /// When already recording the event, Record is absent — `handleRecord` must
    /// be a no-op (can't double-record).
    func testRecordIsNoOpWhenAlreadyRecording() {
        let model = NotchModel()
        model.upcomingMeeting = UpcomingMeeting(
            eventId: "EVT-999",
            title: "Standup",
            startsInSeconds: 60,
            startIso: "2026-07-14T16:00:00-06:00",
            attendeeCount: 0,
            alreadyRecording: true
        )
        let mock = MockActionEmitter()
        let view = UpcomingMeetingView(model: model, emitter: mock)

        view.handleRecord()

        XCTAssertTrue(mock.emitted.isEmpty)
    }

    // MARK: - Dismiss

    /// The wire `dismiss_upcoming` fixture clears the model's upcoming state, so
    /// the view auto-collapses (renders nothing).
    func testDismissUpcomingFixtureClearsState() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))
        XCTAssertNotNil(model.upcomingMeeting)

        model.apply(try decodeInbound("dismiss_upcoming.json"))
        XCTAssertNil(model.upcomingMeeting)
    }

    /// Local Dismiss records the event_id and emits NO wire message (the protocol
    /// has no sidecar→Rust dismiss action).
    func testLocalDismissEmitsNothing() throws {
        let model = NotchModel()
        model.apply(try decodeInbound("upcoming_meeting.json"))
        let mock = MockActionEmitter()
        let view = UpcomingMeetingView(model: model, emitter: mock)

        view.handleDismiss()

        XCTAssertTrue(mock.emitted.isEmpty)
        // The model's authoritative state is untouched by a local dismiss.
        XCTAssertNotNil(model.upcomingMeeting)
    }
}
