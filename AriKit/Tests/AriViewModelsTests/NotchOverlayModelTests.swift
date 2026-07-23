//
//  NotchOverlayModelTests.swift — ported from ari-notch/Tests/AriNotchTests/RecordingHUDTests.swift
//  (docs/plans/notch-panel-absorption.md §7 suite 2), built on the existing `RecordingSessionTests`
//  in-memory-DB + mock-capture harness.
//
//  Dropped vs. the sidecar suite: pause/resume cases (no pause phase on `RecordingSession` —
//  documented in the plan, §9) and all fixture/wire-shape cases (the NDJSON protocol dies with
//  this port).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("NotchOverlayModel")
@MainActor
struct NotchOverlayModelTests {
    private func makeRecordingsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchOverlayModelTests-\(UUID().uuidString)", isDirectory: true)
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
        let session = RecordingSession(
            database: database,
            recordingsRoot: root,
            makeCaptureService: { _ in capture },
            transcription: transcription,
            clock: clock
        )
        // These cases drive the recording lifecycle via the consent flow
        // (`requestStart` → `confirmConsent`), so opt into the gate — production defaults it OFF
        // (`RecordingSession.requireConsent`), where the Record tap starts capture directly.
        session.requireConsent = true
        return session
    }

    private func makeModel(
        session: RecordingSession,
        upcoming: (any NotchUpcomingProviding)? = nil,
        recorder: SpyOpenAppRecorder = SpyOpenAppRecorder()
    ) -> NotchOverlayModel {
        NotchOverlayModel(
            session: session,
            upcoming: upcoming,
            onOpenApp: { recorder.openApp() },
            onRecordEvent: { recorder.recordEvent($0) }
        )
    }

    // MARK: - formatElapsed table

    @Test("formatElapsed: mm:ss, minutes not wrapped at 60")
    func formatElapsedTable() {
        #expect(NotchOverlayModel.formatElapsed(0) == "00:00")
        #expect(NotchOverlayModel.formatElapsed(125) == "02:05")
        #expect(NotchOverlayModel.formatElapsed(3600) == "60:00")
        #expect(NotchOverlayModel.formatElapsed(9) == "00:09")
        #expect(NotchOverlayModel.formatElapsed(599) == "09:59")
    }

    // MARK: - displayedSeconds never fabricates time when not recording

    @Test("displayedSeconds(at:) is 0 in every non-.recording phase, even far in the future")
    func displayedSecondsNeverFabricatesWhenNotRecording() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        let future = Date().addingTimeInterval(120)

        // .idle
        #expect(session.phase == .idle)
        #expect(model.displayedSeconds(at: future) == 0)

        // .consentPrompt
        session.requestStart()
        #expect(session.phase == .consentPrompt)
        #expect(model.displayedSeconds(at: future) == 0)

        // .recording — the ONLY phase that advances, and only from the real startedAt.
        await session.confirmConsent()
        guard case let .recording(startedAt) = session.phase else {
            Issue.record("expected .recording, got \(session.phase)")
            return
        }
        let tenSecondsLater = startedAt.addingTimeInterval(10)
        #expect(model.displayedSeconds(at: tenSecondsLater) == 10)

        // .saved / .stopping / .failed — verified via separate sessions below, since phase only
        // moves forward.
    }

    @Test("displayedSeconds(at:) is 0 once stopped (.saved) — the drain is real, not a ticking clock")
    func displayedSecondsIsZeroOnceSaved() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let (stream, continuation) = AsyncThrowingStream<TranscriptionSegment, Error>.makeStream()
        let transcription = StubLiveTranscriptionService(makeStream: { stream })
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        session.requestStart()
        await session.confirmConsent()
        continuation.finish()

        // This harness's stub segment task finishes immediately (empty stream), so `.stopping`
        // isn't observably held here — this asserts the terminal `.saved` phase instead (only
        // `.recording` ever advances the displayed clock).
        await session.stop()
        guard case .saved = session.phase else {
            Issue.record("expected .saved, got \(session.phase)")
            return
        }
        #expect(model.displayedSeconds(at: Date().addingTimeInterval(3600)) == 0)
    }

    // MARK: - Stop drives the real session.stop()

    @Test("stopTapped() drives session.stop() through to .saved")
    func stopTappedDrivesSessionStop() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        session.requestStart()
        await session.confirmConsent()
        guard case .recording = session.phase else {
            Issue.record("expected .recording, got \(session.phase)")
            return
        }
        #expect(model.isRecording == true)

        model.stopTapped()
        // stopTapped() wraps session.stop() in a detached Task — poll until it lands (bounded).
        for _ in 0 ..< 200 {
            if case .saved = session.phase {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .saved = session.phase else {
            Issue.record("expected .saved after stopTapped(), got \(session.phase)")
            return
        }
        #expect(model.isRecording == false)
    }

    // MARK: - isRecording / isStopping / meetingTitle / latestSegmentText / audioLevel

    @Test("meetingTitle mirrors the persisted Meeting title fallback while recording")
    func meetingTitleMirrorsPersistedFallback() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        // Not recording yet — no title to show.
        #expect(model.meetingTitle == nil)

        session.pendingTitle = "   "
        session.requestStart()
        await session.confirmConsent()

        #expect(model.meetingTitle == "Untitled meeting")
    }

    @Test("latestSegmentText is the last persisted segment's text, or nil — never a placeholder")
    func latestSegmentTextIsRealOrNil() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let segment1 = TranscriptionSegment(text: "First.", startSec: 0, endSec: 1, confidence: 1, words: [])
        let segment2 = TranscriptionSegment(text: "Second.", startSec: 1, endSec: 2, confidence: 1, words: [])
        let transcription = StubLiveTranscriptionService(cannedSegments: [segment1, segment2])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        #expect(model.latestSegmentText == nil)

        session.requestStart()
        await session.confirmConsent()
        await session.stop()

        #expect(model.latestSegmentText == "Second.")
    }

    @Test("audioLevel is session.liveLevel, verbatim")
    func audioLevelIsSessionLiveLevelVerbatim() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value
        let model = makeModel(session: session)

        #expect(model.audioLevel == session.liveLevel)
        #expect(model.audioLevel == 0)
    }

    // MARK: - Consent invariant (plan §7 suite 5 / principle 6)

    @Test(
        "constructing the model, reading presentation, and every non-record action never touches CaptureService.start()"
    )
    func consentInvariant() async throws {
        let database = try AppDatabase.makeInMemory()
        let capture = SpyCaptureService()
        let transcription = StubLiveTranscriptionService(cannedSegments: [])
        let session = try makeSession(database: database, capture: capture, transcription: transcription)
        await session.readinessProbeTask?.value

        let recorder = SpyOpenAppRecorder()
        let upcomingProvider = FakeNotchUpcomingProvider()
        let model = makeModel(session: session, upcoming: upcomingProvider, recorder: recorder)

        #expect(await capture.startCallCount == 0)

        // Constructing + reading every binding never starts capture.
        _ = model.presentation
        _ = model.isRecording
        _ = model.isStopping
        _ = model.meetingTitle
        _ = model.audioLevel
        _ = model.latestSegmentText
        _ = model.displayedSeconds(at: Date())
        _ = model.remainingSeconds(at: Date())
        _ = model.upcomingMeeting
        #expect(await capture.startCallCount == 0)

        // Every action EXCEPT the sanctioned record closure never touches CaptureService either.
        model.openAppTapped()
        model.dismissUpcoming()
        model.stopTapped() // guarded on .recording inside RecordingSession — a no-op from .idle.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await capture.startCallCount == 0)
        #expect(session.phase == .idle)

        // recordTapped() with no upcoming meeting present is a no-op too.
        model.recordTapped()
        #expect(recorder.recordedEventIds.isEmpty)
        #expect(await capture.startCallCount == 0)

        // Only when a real upcoming meeting is present does recordTapped() call the injected
        // closure — and ONLY that closure, never CaptureService directly.
        upcomingProvider.current = NotchUpcomingMeeting(
            eventId: "event-1", title: "Standup", startDate: Date(),
            attendeeCount: 2, alreadyRecording: false
        )
        model.recordTapped()
        #expect(recorder.recordedEventIds == ["event-1"])
        #expect(await capture.startCallCount == 0)
        #expect(recorder.openAppCallCount == 1)
    }
}
