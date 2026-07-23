//
//  NotchUpcomingSchedulerTests.swift — the live `NotchUpcomingProviding` conformer, against an
//  in-memory-DB harness + injected clock (docs/plans/notch-panel-absorption.md Amendment A §A.6
//  suite 14). `evaluateNow()` is the tick body minus sleeping — every test drives it directly,
//  never racing the background tick `Task`.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("NotchUpcomingScheduler")
@MainActor
struct NotchUpcomingSchedulerTests {
    private func makeRecordingsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchUpcomingSchedulerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(database: AppDatabase) throws -> RecordingSession {
        let root = try makeRecordingsRoot()
        let session = RecordingSession(
            database: database,
            recordingsRoot: root,
            makeCaptureService: { _ in SpyCaptureService() },
            transcription: StubLiveTranscriptionService(cannedSegments: [])
        )
        // Keep the documented `.idle -> .consentPrompt` transition below exact — production
        // defaults consent OFF (`RecordingSession.requireConsent`), where Record starts directly.
        session.requireConsent = true
        return session
    }

    private func makeEvent(
        id: String,
        title: String,
        start: Date,
        attendeeCount: Int = 2,
        hasMeeting: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(id),
            calendarId: "cal-1",
            title: title,
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            isAllDay: false,
            attendees: (0 ..< attendeeCount).map { Attendee(name: "Attendee \($0)") },
            meetingId: hasMeeting ? MeetingID("meeting-\(id)") : nil
        )
    }

    /// A fixed anchor "now" so lead-minute arithmetic is exact, mirroring the planner tests' own
    /// fixed anchor. `nonisolated`: a plain `Sendable` `Date` value, needed inside the `@Sendable`
    /// clock closures passed to `NotchUpcomingScheduler.init`.
    private nonisolated static let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// A mutable clock for the one test that advances "now" mid-test
    /// (`lingerExpiryClearsCurrent`). The scheduler's `now` clock closure is synchronous
    /// (`@Sendable () -> Date`), so an `actor` (which would require `await` to read) can't back
    /// it; `NSLock` gives this a genuinely thread-safe read/write, unlike a bare
    /// `nonisolated(unsafe)` var — `@unchecked Sendable` here is a real, lock-protected value, the
    /// canonical accepted use of the annotation.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ now: Date) {
            current = now
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(to date: Date) {
            lock.lock()
            defer { lock.unlock() }
            current = date
        }
    }

    // MARK: - evaluateNow() at T-lead publishes `current` with real event data

    @Test("evaluateNow() at T-lead publishes current with the event's real title/start/attendee count")
    func evaluateNowAtLeadPublishesCurrent() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(10, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)

        let start = Self.referenceNow.addingTimeInterval(10 * 60)
        let event = makeEvent(id: "event-1", title: "Standup", start: start, attendeeCount: 3)
        try await database.calendarEvents.upsert(event)

        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { Self.referenceNow }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )

        await scheduler.evaluateNow()

        #expect(scheduler.current?.eventId == "event-1")
        #expect(scheduler.current?.title == "Standup")
        #expect(scheduler.current?.startDate == start)
        #expect(scheduler.current?.attendeeCount == 3)
    }

    // MARK: - Linger expiry clears `current`

    @Test("linger expiry clears current")
    func lingerExpiryClearsCurrent() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(5, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)

        let start = Self.referenceNow.addingTimeInterval(5 * 60)
        let event = makeEvent(id: "event-1", title: "Standup", start: start)
        try await database.calendarEvents.upsert(event)

        let clock = ClockBox(Self.referenceNow)
        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { clock.now }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )

        await scheduler.evaluateNow()
        #expect(scheduler.current != nil)

        // Advance past the linger window (30 min past start).
        clock.advance(to: start.addingTimeInterval(NotchUpcomingPlanner.lingerAfterStart + 1))
        await scheduler.evaluateNow()

        #expect(scheduler.current == nil)
    }

    // MARK: - Gained meetingId clears `current`

    @Test("a gained meetingId clears current")
    func gainedMeetingIdClearsCurrent() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(5, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)

        let start = Self.referenceNow.addingTimeInterval(5 * 60)
        let event = makeEvent(id: "event-1", title: "Standup", start: start)
        try await database.calendarEvents.upsert(event)

        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { Self.referenceNow }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )

        await scheduler.evaluateNow()
        #expect(scheduler.current != nil)

        // Link the event to a meeting (still before start) and re-evaluate.
        let meetingId = MeetingID("meeting-1")
        try await database.meetings.upsert(Meeting(
            id: meetingId, title: "Standup", createdAt: Self.referenceNow, updatedAt: Self.referenceNow
        ))
        var linked = event
        linked.meetingId = meetingId
        linked.linkSource = .manual
        try await database.calendarEvents.upsert(linked)

        await scheduler.evaluateNow()

        #expect(scheduler.current == nil)
    }

    // MARK: - alreadyRecording derivation

    @Test("alreadyRecording is false when session.phase == .idle")
    func alreadyRecordingFalseWhenIdle() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(5, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)

        let start = Self.referenceNow.addingTimeInterval(5 * 60)
        let event = makeEvent(id: "event-1", title: "Standup", start: start)
        try await database.calendarEvents.upsert(event)

        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { Self.referenceNow }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )
        await scheduler.evaluateNow()

        #expect(scheduler.current?.alreadyRecording == false)
    }

    @Test("alreadyRecording is true under an in-flight phase (.consentPrompt)")
    func alreadyRecordingTrueUnderInFlightPhase() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(5, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)
        await session.readinessProbeTask?.value

        let start = Self.referenceNow.addingTimeInterval(5 * 60)
        let event = makeEvent(id: "event-1", title: "Standup", start: start)
        try await database.calendarEvents.upsert(event)

        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { Self.referenceNow }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )
        await scheduler.evaluateNow()
        #expect(scheduler.current?.alreadyRecording == false)

        session.requestStart() // .idle -> .consentPrompt

        // `current` is a computed property re-derived live — no re-evaluation needed.
        #expect(scheduler.current?.alreadyRecording == true)
    }

    // MARK: - Lead read from settings, with the documented default on absence

    @Test("the lead is read from the settings key, with SettingsViewModel.Defaults.reminderLeadMinutes on absence")
    func leadDefaultsWhenSettingsKeyAbsent() async throws {
        let database = try AppDatabase.makeInMemory()
        // No setting written — the scheduler must fall back to the documented default (5 min).
        let session = try makeSession(database: database)

        let start = Self.referenceNow.addingTimeInterval(
            Double(SettingsViewModel.Defaults.reminderLeadMinutes) * 60
        )
        let event = makeEvent(id: "event-1", title: "Standup", start: start)
        try await database.calendarEvents.upsert(event)

        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { Self.referenceNow }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )
        await scheduler.evaluateNow()

        #expect(scheduler.current?.eventId == "event-1")
    }

    // MARK: - dismissUpcoming() against the LIVE conformer (plan §A.6 item 15)

    @Test(
        "dismissUpcoming() hides the alert while the scheduler still holds it, and a DIFFERENT subsequent event shows again"
    )
    func dismissThenDifferentEventShowsAgainAgainstLiveConformer() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.settings.setInt(5, forKey: .notificationsReminderLeadMinutes)
        let session = try makeSession(database: database)

        let firstStart = Self.referenceNow.addingTimeInterval(5 * 60)
        let firstEvent = makeEvent(id: "event-1", title: "Standup", start: firstStart)
        try await database.calendarEvents.upsert(firstEvent)

        let clock = ClockBox(Self.referenceNow)
        let scheduler = NotchUpcomingScheduler(
            database: database, session: session,
            now: { clock.now }, tickInterval: .seconds(30), initialDelay: .seconds(3600)
        )
        await scheduler.evaluateNow()
        #expect(scheduler.current?.eventId == "event-1")

        let recorder = SpyOpenAppRecorder()
        let model = NotchOverlayModel(
            session: session, upcoming: scheduler,
            onOpenApp: { recorder.openApp() }, onRecordEvent: { recorder.recordEvent($0) }
        )
        #expect(model.upcomingMeeting?.eventId == "event-1")

        model.dismissUpcoming()

        // Hidden from the model's own surface...
        #expect(model.upcomingMeeting == nil)
        #expect(model.presentation == .hidden)
        // ...but the scheduler's authoritative state is untouched (local-only dismiss).
        #expect(scheduler.current?.eventId == "event-1")

        // A second, different event fires at its own T-5 lead.
        let secondStart = Self.referenceNow.addingTimeInterval(20 * 60)
        let secondEvent = makeEvent(id: "event-2", title: "1:1", start: secondStart)
        try await database.calendarEvents.upsert(secondEvent)
        clock.advance(to: secondStart.addingTimeInterval(-5 * 60))
        await scheduler.evaluateNow()

        #expect(scheduler.current?.eventId == "event-2")
        #expect(model.upcomingMeeting?.eventId == "event-2")
        #expect(model.presentation == .expanded)
    }
}
