//
//  NotchUpcomingModelTests.swift — ported from
//  ari-notch/Tests/AriNotchTests/UpcomingMeetingTests.swift
//  (docs/plans/notch-panel-absorption.md §7 suite 3).
//
//  Dropped vs. the sidecar suite: fixture decode + flat-wire-encode cases (the NDJSON protocol
//  dies with this port). No live `NotchUpcomingProviding` conformer ships in this feature (plan
//  §4, §9) — these tests drive `FakeNotchUpcomingProvider` directly.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("NotchUpcomingModel")
@MainActor
struct NotchUpcomingModelTests {
    private func makeRecordingsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchUpcomingModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeIdleSession(database: AppDatabase) throws -> RecordingSession {
        let root = try makeRecordingsRoot()
        return RecordingSession(
            database: database,
            recordingsRoot: root,
            makeCaptureService: { _ in SpyCaptureService() },
            transcription: StubLiveTranscriptionService(cannedSegments: [])
        )
    }

    private func makeModel(
        session: RecordingSession,
        upcoming: any NotchUpcomingProviding,
        recorder: SpyOpenAppRecorder = SpyOpenAppRecorder()
    ) -> NotchOverlayModel {
        NotchOverlayModel(
            session: session,
            upcoming: upcoming,
            onOpenApp: { recorder.openApp() },
            onRecordEvent: { recorder.recordEvent($0) }
        )
    }

    // MARK: - formatCountdown table

    @Test("formatCountdown: mm:ss, minutes not wrapped at 60, 'Starting now' at zero")
    func formatCountdownTable() {
        #expect(NotchOverlayModel.formatCountdown(300) == "05:00")
        #expect(NotchOverlayModel.formatCountdown(125) == "02:05")
        #expect(NotchOverlayModel.formatCountdown(59) == "00:59")
        #expect(NotchOverlayModel.formatCountdown(3600) == "60:00")
        #expect(NotchOverlayModel.formatCountdown(0) == "Starting now")
    }

    // MARK: - formatAttendees

    @Test("formatAttendees: singular/plural")
    func formatAttendeesSingularPlural() {
        #expect(NotchOverlayModel.formatAttendees(1) == "1 attendee")
        #expect(NotchOverlayModel.formatAttendees(2) == "2 attendees")
    }

    // MARK: - Countdown clamp-at-zero (never negative)

    @Test("remainingSeconds(at:) clamps at 0 once startDate has passed — never negative")
    func remainingSecondsClampsAtZero() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value

        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = FakeNotchUpcomingProvider(current: NotchUpcomingMeeting(
            eventId: "event-1", title: "Standup", startDate: startDate,
            attendeeCount: 2, alreadyRecording: false
        ))
        let model = makeModel(session: session, upcoming: provider)

        // 5 minutes before start: 300 seconds remaining.
        #expect(model.remainingSeconds(at: startDate.addingTimeInterval(-300)) == 300)
        // Exactly at start: 0.
        #expect(model.remainingSeconds(at: startDate) == 0)
        // Well PAST start: still 0, never negative.
        #expect(model.remainingSeconds(at: startDate.addingTimeInterval(600)) == 0)
    }

    @Test("remainingSeconds(at:) is 0 when there is no upcoming meeting")
    func remainingSecondsIsZeroWithNoUpcoming() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session, upcoming: FakeNotchUpcomingProvider())

        #expect(model.remainingSeconds(at: Date()) == 0)
    }

    // MARK: - recordTapped() no-op when alreadyRecording (can't double-record)

    @Test("recordTapped() is a no-op when the upcoming meeting is already being recorded")
    func recordTappedNoOpWhenAlreadyRecording() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value

        let provider = FakeNotchUpcomingProvider(current: NotchUpcomingMeeting(
            eventId: "event-1", title: "Standup", startDate: Date(),
            attendeeCount: 0, alreadyRecording: true
        ))
        let recorder = SpyOpenAppRecorder()
        let model = makeModel(session: session, upcoming: provider, recorder: recorder)

        model.recordTapped()

        #expect(recorder.recordedEventIds.isEmpty)
    }

    @Test("recordTapped() calls onRecordEvent with the current event id when not already recording")
    func recordTappedCallsOnRecordEvent() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value

        let provider = FakeNotchUpcomingProvider(current: NotchUpcomingMeeting(
            eventId: "event-42", title: "Standup", startDate: Date(),
            attendeeCount: 3, alreadyRecording: false
        ))
        let recorder = SpyOpenAppRecorder()
        let model = makeModel(session: session, upcoming: provider, recorder: recorder)

        model.recordTapped()

        #expect(recorder.recordedEventIds == ["event-42"])
    }

    // MARK: - Local dismiss emits nothing and leaves the provider untouched

    @Test("dismissUpcoming() hides the alert locally, emits nothing, and leaves the provider's state untouched")
    func localDismissEmitsNothingAndLeavesProviderUntouched() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value

        let meeting = NotchUpcomingMeeting(
            eventId: "event-1", title: "Standup", startDate: Date(),
            attendeeCount: 2, alreadyRecording: false
        )
        let provider = FakeNotchUpcomingProvider(current: meeting)
        let recorder = SpyOpenAppRecorder()
        let model = makeModel(session: session, upcoming: provider, recorder: recorder)

        #expect(model.upcomingMeeting == meeting)
        #expect(model.presentation == .expanded)

        model.dismissUpcoming()

        // The alert is hidden from the model's own surface...
        #expect(model.upcomingMeeting == nil)
        #expect(model.presentation == .hidden)
        // ...but the provider's authoritative state is completely untouched (a future scheduler
        // conformer would still see the same meeting), and nothing was emitted.
        #expect(provider.current == meeting)
        #expect(recorder.recordedEventIds.isEmpty)
        #expect(recorder.openAppCallCount == 0)
    }

    @Test("a DIFFERENT event arriving after a dismiss is shown again")
    func differentEventAfterDismissIsShownAgain() async throws {
        let database = try AppDatabase.makeInMemory()
        let session = try makeIdleSession(database: database)
        await session.readinessProbeTask?.value

        let firstMeeting = NotchUpcomingMeeting(
            eventId: "event-1", title: "Standup", startDate: Date(),
            attendeeCount: 2, alreadyRecording: false
        )
        let provider = FakeNotchUpcomingProvider(current: firstMeeting)
        let model = makeModel(session: session, upcoming: provider)

        model.dismissUpcoming()
        #expect(model.upcomingMeeting == nil)

        let secondMeeting = NotchUpcomingMeeting(
            eventId: "event-2", title: "1:1", startDate: Date(),
            attendeeCount: 1, alreadyRecording: false
        )
        provider.current = secondMeeting

        #expect(model.upcomingMeeting == secondMeeting)
        #expect(model.presentation == .expanded)
    }
}
