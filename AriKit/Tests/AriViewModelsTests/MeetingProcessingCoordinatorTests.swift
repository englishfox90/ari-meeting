//
//  MeetingProcessingCoordinatorTests.swift — docs/plans/swift-meeting-generation-flow.md,
//  Track 2 "Acceptance tests".
//
//  Closure-level tests (mirrors `SpeakerIdentificationViewModelTests`/
//  `MeetingSummaryViewModelTests`): the closure-injected designated `init` is exercised directly,
//  so these stay headless and independent of `AppDatabase`/`DiarizationService`/`SummaryRunner`
//  wiring (that composition lives in `AppEnvironment.bootstrap()`).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingProcessingCoordinator")
@MainActor
struct MeetingProcessingCoordinatorTests {
    private let meetingId: MeetingID = "meeting-1"
    private let meetingId2: MeetingID = "meeting-2"
    private let audioURL = URL(fileURLWithPath: "/tmp/meeting-1.m4a")

    private struct StubError: Error, CustomStringConvertible {
        var description: String { "stub error" }
    }

    private actor CallSpy<Value: Sendable> {
        private(set) var callCount = 0
        private(set) var lastValue: Value?

        func record(_ value: Value? = nil) {
            callCount += 1
            lastValue = value
        }
    }

    private func makeCoordinator(
        resolveAudioURL: @escaping MeetingProcessingCoordinator.ResolveAudioURLOperation = { _ in nil },
        resolveHint: @escaping MeetingProcessingCoordinator.ResolveHintOperation = { _ in nil },
        runDiarization: @escaping MeetingProcessingCoordinator.RunDiarizationOperation = { _, _, _, _ in },
        isAutoSummaryEnabled: @escaping MeetingProcessingCoordinator.IsAutoSummaryEnabledOperation = { true },
        generateSummary: @escaping MeetingProcessingCoordinator.GenerateSummaryOperation = { _, _ in },
        speakerCount: @escaping MeetingProcessingCoordinator.SpeakerCountOperation = { _ in nil },
        cancelSummary: @escaping MeetingProcessingCoordinator.CancelSummaryOperation = { _ in }
    ) -> MeetingProcessingCoordinator {
        MeetingProcessingCoordinator(
            resolveAudioURL: resolveAudioURL,
            resolveHint: resolveHint,
            runDiarization: runDiarization,
            isAutoSummaryEnabled: isAutoSummaryEnabled,
            generateSummary: generateSummary,
            speakerCount: speakerCount,
            cancelSummary: cancelSummary
        )
    }

    @Test("honest idle before any begin() call")
    func honestIdleBeforeBegin() {
        let coordinator = makeCoordinator()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeMeetingID == nil)
        #expect(coordinator.diarizationNote == nil)
    }

    @Test("hint present: runs diarization (progress reaches phase) then summarizes to completed")
    func hintPresentRunsFullPipeline() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let summarySpy = CallSpy<Int?>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in .exact(2) },
            runDiarization: { _, _, _, progress in
                progress(.preparingModels, 0.0)
                progress(.diarizing, 0.5)
                for await _ in gate { break }
            },
            generateSummary: { _, count in await summarySpy.record(count) },
            speakerCount: { _ in 2 }
        )

        let task = Task { await coordinator.begin(meetingId: meetingId) }

        var observedDiarizing = false
        while true {
            if case .identifyingSpeakers(.diarizing, _) = coordinator.phase {
                observedDiarizing = true
                break
            }
            if case .completed = coordinator.phase { break }
            if case .failed = coordinator.phase { break }
            await Task.yield()
        }
        gateContinuation.finish()
        await task.value

        #expect(observedDiarizing, "diarization progress must reach the coordinator's live phase")
        #expect(coordinator.phase == .completed)
        #expect(coordinator.diarizationNote == nil)
        #expect(await summarySpy.callCount == 1)
        #expect(await summarySpy.lastValue == 2)
    }

    @Test("hint nil pauses at needsSpeakerCount; provideSpeakerCount resumes to completed")
    func hintNilPausesThenResumesWithCount() async {
        let diarizeSpy = CallSpy<SpeakerCountHint>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in nil },
            runDiarization: { _, _, hint, progress in
                await diarizeSpy.record(hint)
                progress(.preparingModels, 1.0)
            }
        )

        await coordinator.begin(meetingId: meetingId)
        #expect(coordinator.phase == .needsSpeakerCount)
        #expect(coordinator.activeMeetingID == meetingId)

        await coordinator.provideSpeakerCount(.exact(3))

        #expect(coordinator.phase == .completed)
        #expect(await diarizeSpy.callCount == 1)
        #expect(await diarizeSpy.lastValue == .exact(3))
    }

    @Test("hint nil pauses at needsSpeakerCount; skipSpeakerIdentification resumes skipping diarization")
    func hintNilPausesThenSkips() async {
        let diarizeSpy = CallSpy<Never>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in nil },
            runDiarization: { _, _, _, _ in await diarizeSpy.record() }
        )

        await coordinator.begin(meetingId: meetingId)
        #expect(coordinator.phase == .needsSpeakerCount)

        await coordinator.skipSpeakerIdentification()

        #expect(coordinator.phase == .completed)
        #expect(await diarizeSpy.callCount == 0)
        #expect(coordinator.diarizationNote == nil)
    }

    @Test("no audio skips speaker identification entirely but still summarizes")
    func noAudioSkipsSpeakerIDButStillSummarizes() async {
        let diarizeSpy = CallSpy<Never>()
        let summarySpy = CallSpy<Int?>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { _ in nil },
            runDiarization: { _, _, _, _ in await diarizeSpy.record() },
            generateSummary: { _, count in await summarySpy.record(count) }
        )

        await coordinator.begin(meetingId: meetingId)

        #expect(coordinator.phase == .completed)
        #expect(await diarizeSpy.callCount == 0)
        #expect(await summarySpy.callCount == 1)
    }

    @Test("diarization failure is non-fatal: an honest note is recorded, pipeline still completes")
    func diarizationFailureIsNonFatal() async {
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in .exact(2) },
            runDiarization: { _, _, _, _ in throw StubError() }
        )

        await coordinator.begin(meetingId: meetingId)

        #expect(coordinator.phase == .completed)
        #expect(coordinator.diarizationNote != nil)
    }

    @Test("summaryAutomatic == false stops at completed with no summary generated")
    func summaryAutomaticFalseSkipsGeneration() async {
        let summarySpy = CallSpy<Never>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { _ in nil },
            isAutoSummaryEnabled: { false },
            generateSummary: { _, _ in await summarySpy.record() }
        )

        await coordinator.begin(meetingId: meetingId)

        #expect(coordinator.phase == .completed)
        #expect(await summarySpy.callCount == 0)
    }

    @Test("summary generation failure surfaces honestly as .failed")
    func summaryFailureSurfacesAsFailed() async {
        let coordinator = makeCoordinator(
            resolveAudioURL: { _ in nil },
            generateSummary: { _, _ in throw StubError() }
        )

        await coordinator.begin(meetingId: meetingId)

        guard case let .failed(message) = coordinator.phase else {
            Issue.record("expected .failed, got \(coordinator.phase)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("summary cancellation resolves to .idle, not .failed")
    func summaryCancellationResolvesToIdle() async {
        let coordinator = makeCoordinator(
            resolveAudioURL: { _ in nil },
            generateSummary: { _, _ in throw CancellationError() }
        )

        await coordinator.begin(meetingId: meetingId)

        #expect(coordinator.phase == .idle)
    }

    @Test("cancel() during diarization aborts the pipeline — no summary, no dishonest note")
    func cancelDuringDiarizationAborts() async {
        let summarySpy = CallSpy<Int?>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in .exact(2) },
            runDiarization: { _, _, _, progress in
                progress(.diarizing, 0.5)
                // Cancellation-aware wait: `cancel()` cancels the run task, so this throws
                // `CancellationError` — exactly what the real diarization op does under cancel.
                try await Task.sleep(for: .seconds(60))
            },
            generateSummary: { _, count in await summarySpy.record(count) }
        )

        let begin = Task { await coordinator.begin(meetingId: meetingId) }
        while true {
            if case .identifyingSpeakers(.diarizing, _) = coordinator.phase { break }
            if case .completed = coordinator.phase { break }
            if case .failed = coordinator.phase { break }
            await Task.yield()
        }

        coordinator.cancel()
        await begin.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeMeetingID == nil)
        // The cancel must NOT be recorded as a diarization "failure", and must NOT proceed to
        // generate a summary anyway.
        #expect(coordinator.diarizationNote == nil)
        #expect(await summarySpy.callCount == 0)
    }

    @Test("begin is a no-op while actively processing, but starts fresh after a terminal phase")
    func reentrancyGuardThenFreshRestartAfterTerminal() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let diarizeSpy = CallSpy<Never>()
        let coordinator = makeCoordinator(
            resolveAudioURL: { [audioURL] _ in audioURL },
            resolveHint: { _ in .exact(2) },
            runDiarization: { _, _, _, _ in
                await diarizeSpy.record()
                for await _ in gate { break }
            }
        )

        let firstBegin = Task { await coordinator.begin(meetingId: meetingId) }
        while coordinator.phase == .idle {
            await Task.yield()
        }

        // A reentrant begin() call while a pipeline is actively running is a no-op — it must not
        // start a second underlying diarization run, and the original meeting stays active.
        await coordinator.begin(meetingId: meetingId2)
        #expect(await diarizeSpy.callCount == 1)
        #expect(coordinator.activeMeetingID == meetingId)

        gateContinuation.finish()
        await firstBegin.value
        #expect(coordinator.phase == .completed)

        // A `.completed` terminal phase must never permanently block a later recording's begin.
        await coordinator.begin(meetingId: meetingId2)
        #expect(await diarizeSpy.callCount == 2)
        #expect(coordinator.activeMeetingID == meetingId2)
        #expect(coordinator.phase == .completed)
    }
}
