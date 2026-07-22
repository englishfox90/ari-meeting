//
//  RecordingSessionTests.swift — docs/plans/ari-recording-page.md §6 Lane 1, the 8 cases.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("RecordingSession")
@MainActor
struct RecordingSessionTests {
    private func makeRecordingsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(
        database: AppDatabase,
        capture: SpyCaptureService,
        transcription: any LiveTranscriptionService,
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) throws -> RecordingSession {
        let root = try makeRecordingsRoot()
        return RecordingSession(
            database: database,
            recordingsRoot: root,
            makeCaptureService: { _ in capture },
            transcription: transcription,
            clock: clock
        )
    }

    // MARK: 1. State machine

    @Test("legal transitions advance the phase; illegal ones no-op")
    func stateMachineTransitions() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        // Illegal: stop() from idle is a no-op.
        await session.stop()
        #expect(session.phase == .idle)

        // Illegal: requestStart() while active (recording) is a no-op — exercised after we get
        // into `.recording` below.

        session.requestStart()
        #expect(session.phase == .consentPrompt)

        // Legal: cancelConsent() returns to idle.
        session.cancelConsent()
        #expect(session.phase == .idle)

        session.requestStart()
        #expect(session.phase == .consentPrompt)

        await session.confirmConsent()
        guard case .recording = session.phase else {
            Issue.record("expected .recording, got \(session.phase)")
            return
        }

        // Illegal: a second confirmConsent() once already past .consentPrompt is a no-op — it
        // does not re-enter .starting or start capture again.
        await session.confirmConsent()
        #expect(await capture.startCallCount == 1)
        guard case .recording = session.phase else {
            Issue.record("a second confirmConsent() must not change phase, got \(session.phase)")
            return
        }

        // Illegal: requestStart() while active is a no-op.
        session.requestStart()
        #expect(session.phase != .consentPrompt)
        if case .recording = session.phase {
            // still recording, as expected
        } else {
            Issue.record("requestStart() while active should not change phase, got \(session.phase)")
        }

        await session.stop()
        guard case let .saved(meetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }

        // Legal: reset() from saved returns to idle.
        session.reset()
        #expect(session.phase == .idle)
        #expect(session.meetingId == nil)
        _ = meetingId // silence unused-binding warning if the compiler ever inlines differently
    }

    // MARK: 2. Consent invariant

    @Test("CaptureService.start() is called only downstream of confirmConsent()")
    func consentInvariant() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        #expect(await capture.startCallCount == 0)

        // Constructing + "rendering" (reading phase/segments) never starts capture.
        _ = session.phase
        _ = session.segments
        #expect(await capture.startCallCount == 0)

        // requestStart() alone never starts capture.
        session.requestStart()
        #expect(await capture.startCallCount == 0)
        #expect(session.phase == .consentPrompt)

        // Only confirmConsent() starts capture.
        await session.confirmConsent()
        #expect(await capture.startCallCount == 1)
    }

    // MARK: 3. Live accumulation

    @Test("canned segments accumulate in order, persist, and the Meeting row carries provenance")
    func liveAccumulation() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let segment1 = TranscriptionSegment(text: "First.", startSec: 0, endSec: 1, confidence: 1, words: [])
        let segment2 = TranscriptionSegment(text: "Second.", startSec: 1, endSec: 2, confidence: 1, words: [])
        let transcription = StubLiveTranscriptionService(
            providerName: "stub-live-provider",
            cannedSegments: [segment1, segment2]
        )
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()

        guard case .recording = session.phase, let meetingId = session.meetingId else {
            Issue.record("expected .recording with a meetingId, got \(session.phase)")
            return
        }

        let meeting = try #require(await database.meetings.find(meetingId))
        #expect(meeting.transcriptionProvider == "stub-live-provider")
        #expect(meeting.audioReference != nil)

        // Force a full drain (stop() awaits the segment task's natural completion).
        await session.stop()

        #expect(session.segments.map(\.transcript) == ["First.", "Second."])

        let persisted = try await database.transcripts.forMeeting(meetingId)
        #expect(persisted.map(\.transcript) == ["First.", "Second."])
    }

    // MARK: 4. Start failure honesty

    @Test("a capture-start failure lands in .failed with the real error and leaves no live Meeting row")
    func startFailureHonesty() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        await capture.configureStart(error: SpyError(message: "mic denied"))
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()

        guard case let .failed(message) = session.phase else {
            Issue.record("expected .failed, got \(session.phase)")
            return
        }
        #expect(message.contains("mic denied"))
        #expect(session.meetingId == nil)

        let allMeetings = try await database.meetings.all()
        #expect(allMeetings.isEmpty)
    }

    // MARK: 5. Stop drains

    @Test("a segment still in flight at stop() is persisted before .saved")
    func stopDrains() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let finalURL = URL(fileURLWithPath: "/tmp/stop-drains.m4a")
        await capture.configureFinish(.success(finalURL))

        let (stream, continuation) = AsyncThrowingStream<TranscriptionSegment, Error>.makeStream()
        let transcription = StubLiveTranscriptionService(makeStream: { stream })
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()
        guard let meetingId = session.meetingId else {
            Issue.record("expected a meetingId after confirmConsent()")
            return
        }

        // Yield one segment and close the stream — "still in flight" relative to stop(): the
        // segment task has not necessarily processed it yet when stop() is invoked below.
        let inFlight = TranscriptionSegment(text: "In flight.", startSec: 0, endSec: 1, confidence: 1, words: [])
        continuation.yield(inFlight)
        continuation.finish()

        await session.stop()

        guard case let .saved(savedMeetingId) = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        #expect(savedMeetingId == meetingId)
        #expect(session.segments.map(\.transcript) == ["In flight."])

        let persisted = try await database.transcripts.forMeeting(meetingId)
        #expect(persisted.map(\.transcript) == ["In flight."])
        #expect(await capture.finishCallCount == 1)
    }

    // MARK: 6. Degraded-source honesty

    @Test("mic ready + system unavailable proceeds with systemStatus surfaced")
    func degradedSourceProceeds() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        await capture.configureSourceStatus(mic: .ready, system: .unavailable(reason: "denied"))
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()

        guard case .recording = session.phase else {
            Issue.record("expected .recording, got \(session.phase)")
            return
        }
        #expect(session.micStatus == .ready)
        #expect(session.systemStatus == .unavailable(reason: "denied"))
    }

    @Test("both sources unavailable fails honestly")
    func bothSourcesUnavailableFails() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        await capture.configureStart(error: SpyError(message: "neither source started"))
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()

        guard case let .failed(message) = session.phase else {
            Issue.record("expected .failed, got \(session.phase)")
            return
        }
        #expect(message.contains("neither source started"))
    }

    // MARK: 7. Transcriber readiness pass-through

    @Test("downloadingAssets(progress:) passes through verbatim; unavailable prevents a successful start")
    func transcriberReadinessPassThrough() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(
            readiness: .downloadingAssets(progress: 0.42),
            cannedSegments: []
        )
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        #expect(session.transcriberReadiness == .downloadingAssets(progress: 0.42))

        session.requestStart()
        await session.confirmConsent()

        guard case let .failed(message) = session.phase else {
            Issue.record("expected .failed (unavailable readiness blocks start), got \(session.phase)")
            return
        }
        #expect(message.contains("42"))
        #expect(await capture.startCallCount == 0)
    }

    // MARK: 8. Elapsed derivation

    @Test("startedAt comes from the injected clock, not real wall time")
    func elapsedDerivesFromInjectedClock() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let fixedInstant = Date(timeIntervalSince1970: 1_234_567)
        let session = try makeSession(
            database: database, capture: capture, transcription: transcription,
            clock: { fixedInstant }
        )
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()

        #expect(session.phase == .recording(startedAt: fixedInstant))
    }

    // MARK: R2 additions — idle-screen title + eager source-availability probe

    @Test("confirmConsentRequested() flips to .starting synchronously — a late cancelConsent() no-ops (H3)")
    func synchronousConsentEdgeWinsOverSheetDismiss() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        session.confirmConsentRequested()
        // BEFORE any await: the phase must already have left .consentPrompt, so the sheet
        // dismissal's cancelConsent() (which guards on .consentPrompt) is a guaranteed no-op.
        #expect(session.phase != .consentPrompt)
        session.cancelConsent()
        #expect(session.phase != .idle)

        await session.startTask?.value
        guard case .recording = session.phase else {
            Issue.record("expected .recording after the synchronous consent edge, got \(session.phase)")
            return
        }
        await session.stop()
    }

    @Test("a blank pendingTitle falls back to the honest 'Untitled meeting' default")
    func blankTitleFallsBackToDefault() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        await session.sourceProbeTask?.value

        session.pendingTitle = "   "
        session.requestStart()
        await session.confirmConsent()

        let meetingId = try #require(session.meetingId)
        let meeting = try #require(await database.meetings.find(meetingId))
        #expect(meeting.title == "Untitled meeting")
    }

    @Test("a non-blank pendingTitle is trimmed and used as the Meeting's real title")
    func nonBlankTitleIsUsedVerbatim() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        await session.sourceProbeTask?.value

        session.pendingTitle = "  Weekly sync  "
        session.requestStart()
        await session.confirmConsent()

        let meetingId = try #require(session.meetingId)
        let meeting = try #require(await database.meetings.find(meetingId))
        #expect(meeting.title == "Weekly sync")
    }

    @Test("the init-time source probe populates micStatus/systemStatus before any Record tap")
    func sourceProbePopulatesIdleReadiness() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        await capture.configureSourceStatus(mic: .ready, system: .unavailable(reason: "no tap"))
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        await session.sourceProbeTask?.value

        // No requestStart()/confirmConsent() has happened yet — the probe alone populated these.
        #expect(session.micStatus == .ready)
        #expect(session.systemStatus == .unavailable(reason: "no tap"))
        #expect(await capture.startCallCount == 0)
    }

    // MARK: S7 Slice 3 additions — pending calendar link (docs/plans/arikit-calendar-ui.md §5/§6)

    private func makeCalendarEvent(id: CalendarEventID, title: String = "Weekly Sync") -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: "cal-1", title: title,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_001_800), isAllDay: false, attendees: []
        )
    }

    // MARK: 9. Pending-link consumption

    @Test("a pending calendar link is consumed at meeting creation, then cleared")
    func pendingCalendarLinkIsConsumedAtMeetingCreation() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        try await database.calendarEvents.syncUpsert([makeCalendarEvent(id: "event-1")], at: Date())
        session.pendingCalendarLink = RecordingSession.PendingCalendarLink(eventId: "event-1", eventTitle: "Weekly Sync")

        session.requestStart()
        await session.confirmConsent()

        let meetingId = try #require(session.meetingId)
        #expect(session.pendingCalendarLink == nil)

        let linkedEvent = try #require(await database.calendarEvents.find("event-1"))
        #expect(linkedEvent.meetingId == meetingId)
        #expect(linkedEvent.linkSource == .manual)
    }

    // MARK: 10. Pending-link never blocks

    @Test("a pending link write failure never blocks the recording from starting")
    func pendingCalendarLinkFailureNeverBlocksRecording() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        // The pending event doesn't exist in the store (e.g. deleted before Record was
        // confirmed) — `setManualLink` fetches, finds nothing, and silently no-ops.
        session.pendingCalendarLink = RecordingSession.PendingCalendarLink(
            eventId: "missing-event", eventTitle: "Ghost"
        )

        session.requestStart()
        await session.confirmConsent()

        guard case .recording = session.phase else {
            Issue.record(
                "expected .recording even though the pending link target doesn't exist, got \(session.phase)"
            )
            return
        }
        #expect(session.pendingCalendarLink == nil)
    }

    @Test("cancelling consent writes no link and leaves the pending intent in place for the next attempt")
    func consentCancelWritesNoLink() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        try await database.calendarEvents.syncUpsert([makeCalendarEvent(id: "event-2")], at: Date())
        let pending = RecordingSession.PendingCalendarLink(eventId: "event-2", eventTitle: "Weekly Sync")
        session.pendingCalendarLink = pending

        session.requestStart()
        session.cancelConsent()

        #expect(session.phase == .idle)
        // The chip survives, removable, for the next attempt (plan §5) — never silently dropped.
        #expect(session.pendingCalendarLink == pending)

        let event = try #require(await database.calendarEvents.find("event-2"))
        #expect(event.meetingId == nil)
        #expect(await capture.startCallCount == 0)
    }

    // MARK: 11. Reset clears the pending link

    @Test("reset() clears the pending calendar link alongside pendingTitle")
    func resetClearsPendingCalendarLink() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        session.requestStart()
        await session.confirmConsent()
        // Simulate a leftover pending intent still set at stop()/reset() time (never consumed by
        // this recording, since it was set after the meeting already existed) — reset() must
        // scrub it regardless of how it got there.
        session.pendingCalendarLink = RecordingSession.PendingCalendarLink(eventId: "event-3", eventTitle: "Next one")
        await session.stop()

        guard case .saved = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }

        session.reset()

        #expect(session.phase == .idle)
        #expect(session.pendingTitle == "")
        #expect(session.pendingCalendarLink == nil)
    }
}
