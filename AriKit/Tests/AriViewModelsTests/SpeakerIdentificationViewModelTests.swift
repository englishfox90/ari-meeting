//
//  SpeakerIdentificationViewModelTests.swift — docs/plans/arikit-diarization.md §5 D9a, §7.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("SpeakerIdentificationViewModel (D9a)")
@MainActor
struct SpeakerIdentificationViewModelTests {
    private let meetingId: MeetingID = "meeting-1"
    private let audioURL = URL(fileURLWithPath: "/tmp/meeting-1.m4a")
    private let speakerId: SpeakerID = "speaker-1"
    private let personId: PersonID = "person-1"

    private struct StubHintProvider: SpeakerCountHintProviding {
        var result: ResolvedSpeakerHint?
        var error: Error?

        func hint(for _: MeetingID) async throws -> ResolvedSpeakerHint? {
            if let error { throw error }
            return result
        }
    }

    private struct StubError: Error {}

    private actor CallSpy<Value: Sendable> {
        private(set) var callCount = 0
        private(set) var lastValue: Value?

        func record(_ value: Value? = nil) {
            callCount += 1
            lastValue = value
        }
    }

    private func makeResult() -> DiarizationService.RunResult {
        DiarizationService.RunResult(stampedRows: 1, unresolvedRows: 0, speakers: [])
    }

    private func makeViewModel(
        hintProvider: any SpeakerCountHintProviding = StubHintProvider(),
        isRecording: @escaping @Sendable () -> Bool = { false },
        runOperation: @escaping SpeakerIdentificationViewModel.RunOperation = { _, _, _, _ in
            DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
        },
        confirmOperation: @escaping SpeakerIdentificationViewModel.ConfirmOperation = { _, _, _ in }
    ) -> SpeakerIdentificationViewModel {
        SpeakerIdentificationViewModel(
            hintProvider: hintProvider,
            isRecording: isRecording,
            runOperation: runOperation,
            confirmOperation: confirmOperation
        )
    }

    @Test("honest idle before any run")
    func honestIdleBeforeRun() {
        let viewModel = makeViewModel()
        guard case .idle = viewModel.runState else {
            Issue.record("expected .idle, got \(viewModel.runState)")
            return
        }
        #expect(viewModel.progressHistory.isEmpty)
        #expect(viewModel.prefilledHint == nil)
        #expect(viewModel.resolvedHint == nil)
    }

    @Test("hint prefilled from calendar carries its origin")
    func hintPrefilledFromCalendarWithOrigin() async {
        let resolved = ResolvedSpeakerHint(hint: .upperBound(6), origin: .calendarAttendees)
        let viewModel = makeViewModel(hintProvider: StubHintProvider(result: resolved))

        await viewModel.loadHint(for: meetingId)

        #expect(viewModel.prefilledHint?.origin == .calendarAttendees)
        #expect(viewModel.prefilledHint?.hint == .upperBound(6))
        #expect(viewModel.resolvedHint == .upperBound(6))
    }

    @Test("run requires a count when no hint exists")
    func runRequiresCountWhenNoHint() async {
        let spy = CallSpy<Never>()
        let viewModel = makeViewModel(runOperation: { _, _, _, _ in
            await spy.record()
            return DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
        })

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)

        guard case let .failed(message) = viewModel.runState else {
            Issue.record("expected .failed, got \(viewModel.runState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(await spy.callCount == 0)
    }

    @Test("an uncertain user count maps to .upperBound, never .exact (H2)")
    func userUncertainCountMapsToUpperBoundNotExact() {
        let viewModel = makeViewModel()

        viewModel.setUncertainCount(4)

        guard case .upperBound = viewModel.resolvedHint else {
            Issue.record("expected .upperBound, got \(String(describing: viewModel.resolvedHint))")
            return
        }

        viewModel.setExactCount(4)
        guard case .exact = viewModel.resolvedHint else {
            Issue.record("expected .exact, got \(String(describing: viewModel.resolvedHint))")
            return
        }
    }

    @Test("progress phases reach UI-observable state in order")
    func progressPhasesReachUI() async {
        let viewModel = makeViewModel(runOperation: { _, _, _, progress in
            progress(.preparingModels, 1.0)
            progress(.decodingAudio, 1.0)
            progress(.diarizing, 1.0)
            progress(.matching, 1.0)
            progress(.stamping, 1.0)
            return DiarizationService.RunResult(stampedRows: 2, unresolvedRows: 0, speakers: [])
        })
        viewModel.setExactCount(2)

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)

        #expect(viewModel.progressHistory.count == 5)
        guard case .succeeded = viewModel.runState else {
            Issue.record("expected .succeeded, got \(viewModel.runState)")
            return
        }
    }

    @Test("a provider error surfaces honestly, never a fake success")
    func honestFailedOnProviderError() async {
        let viewModel = makeViewModel(runOperation: { _, _, _, _ in
            throw StubError()
        })
        viewModel.setExactCount(3)

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)

        guard case let .failed(message) = viewModel.runState else {
            Issue.record("expected .failed, got \(viewModel.runState)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("confirm calls the underlying service exactly once")
    func confirmFlowCallsServiceOnce() async {
        let spy = CallSpy<(SpeakerID, PersonID, MeetingID)>()
        let viewModel = makeViewModel(confirmOperation: { speakerId, personId, meetingId in
            await spy.record((speakerId, personId, meetingId))
        })

        await viewModel.confirm(speakerId, as: personId, inMeeting: meetingId)

        let callCount = await spy.callCount
        let seen = await spy.lastValue
        #expect(callCount == 1)
        #expect(seen?.0 == speakerId)
        #expect(seen?.1 == personId)
        #expect(seen?.2 == meetingId)
    }

    @Test("run is disabled while recording is in progress")
    func runDisabledWhileRecording() async {
        let spy = CallSpy<Never>()
        let viewModel = makeViewModel(
            isRecording: { true },
            runOperation: { _, _, _, _ in
                await spy.record()
                return DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
            }
        )
        viewModel.setExactCount(2)

        #expect(viewModel.canRun == false)

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)

        guard case let .failed(message) = viewModel.runState else {
            Issue.record("expected .failed, got \(viewModel.runState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(await spy.callCount == 0)
    }
}
