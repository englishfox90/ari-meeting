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
            if let error {
                throw error
            }
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
        confirmOperation: @escaping SpeakerIdentificationViewModel.ConfirmOperation = { _, _, _ in },
        loadPersistedOperation: @escaping SpeakerIdentificationViewModel.LoadPersistedOperation = { _ in nil },
        likelyPeopleOperation: @escaping SpeakerIdentificationViewModel.LikelyPeopleOperation = { _ in [] }
    ) -> SpeakerIdentificationViewModel {
        SpeakerIdentificationViewModel(
            hintProvider: hintProvider,
            isRecording: isRecording,
            runOperation: runOperation,
            confirmOperation: confirmOperation,
            loadPersistedOperation: loadPersistedOperation,
            likelyPeopleOperation: likelyPeopleOperation
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

        // Exact sequence, not just count (D9a review fix): a phase-reordering bug in the
        // AsyncStream bridge would still pass a bare `.count == 5` assertion.
        #expect(viewModel.progressHistory == [
            .preparingModels, .decodingAudio, .diarizing, .matching, .stamping
        ])
        guard case .succeeded = viewModel.runState else {
            Issue.record("expected .succeeded, got \(viewModel.runState)")
            return
        }
    }

    @Test("a second run() call while already running is refused, not interleaved (D9a review fix)")
    func reentrantRunIsRefused() async {
        let spy = CallSpy<Never>()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let viewModel = makeViewModel(runOperation: { _, _, _, progress in
            await spy.record()
            progress(.preparingModels, 0.0)
            // Block the first run in flight so a concurrent second call observes `.running`.
            for await _ in gate {
                break
            }
            return DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
        })
        viewModel.setExactCount(2)

        let firstRun = Task { await viewModel.run(meetingId: meetingId, audioURL: audioURL) }
        // Give the first run a chance to reach `.running` before firing the second.
        while case .idle = viewModel.runState {
            await Task.yield()
        }

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)
        #expect(await spy.callCount == 1, "the reentrant call must not start a second underlying run")

        gateContinuation.finish()
        await firstRun.value

        guard case .succeeded = viewModel.runState else {
            Issue.record("expected the first (only) run to succeed, got \(viewModel.runState)")
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

    // MARK: - loadPersisted (speaker-retag-and-calendar-candidates.md §2 #2, §5)

    /// A `DiarizationProvider` that fails the test if `diarize`/`prepare` is ever invoked — the
    /// load-bearing proof that reconstruction never re-runs the pipeline.
    private struct FailingDiarizationProvider: DiarizationProvider {
        let providerName = "failing-stub"
        let embeddingModel = "fluidaudio-community-1"
        func isAvailable() async -> Bool {
            true
        }

        func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
            Issue.record("prepare() must never be called by loadPersisted")
        }

        func diarize(
            samples _: [Float], hint _: SpeakerCountHint, progress: (@Sendable (Double) -> Void)?
        ) async throws -> DiarizationOutput {
            Issue.record("diarize() must never be called by loadPersisted")
            return DiarizationOutput(segments: [], clusters: [], embeddingModel: embeddingModel, dim: 2)
        }
    }

    /// A `DiarizationAudioLoading` that fails the test if `load16kMono` is ever invoked.
    private struct FailingAudioLoader: DiarizationAudioLoading {
        func load16kMono(from _: URL) async throws -> [Float] {
            Issue.record("load16kMono() must never be called by loadPersisted")
            return []
        }
    }

    private func makeReconstructableDatabase() async throws -> AppDatabase {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: meetingId, title: "Meeting", createdAt: instant, updatedAt: instant))
        try await db.speakers.upsert(Speaker(
            id: speakerId, personId: nil, centroid: Data([0, 1, 2, 3]),
            embeddingModel: "fluidaudio-community-1", dim: 2, samples: 1,
            enrollmentState: .provisional, totalSpeechSecs: 0, createdAt: instant, updatedAt: instant
        ))
        try await db.speakerSegments.upsert(SpeakerSegment(
            id: "seg-1", meetingId: meetingId, speakerId: speakerId, clusterKey: "S",
            startTime: 0, endTime: 10, source: .system, createdAt: instant
        ))
        return db
    }

    @Test(
        "loadPersisted reaches .reconstructed via a real DiarizationService without ever re-diarizing (load-bearing #2 proof)"
    )
    func loadPersistedReachesAssignUIWithZeroDiarizeCalls() async throws {
        let db = try await makeReconstructableDatabase()
        let service = DiarizationService(
            database: db, provider: FailingDiarizationProvider(), audioLoader: FailingAudioLoader()
        )
        let runSpy = CallSpy<Never>()
        let viewModel = makeViewModel(
            runOperation: { _, _, _, _ in
                await runSpy.record()
                Issue.record("runOperation must never be called by loadPersisted")
                return DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
            },
            loadPersistedOperation: { meetingId in
                try await service.loadPersisted(meetingId: meetingId)
            }
        )

        await viewModel.loadPersisted(meetingId: meetingId)

        guard case let .reconstructed(result) = viewModel.runState else {
            Issue.record("expected .reconstructed, got \(viewModel.runState)")
            return
        }
        #expect(result.speakers.map(\.speakerId) == [speakerId])
        #expect(await runSpy.callCount == 0)
    }

    @Test("loadPersisted leaves runState untouched when the operation returns nil (never diarized)")
    func loadPersistedNilLeavesIdle() async {
        let viewModel = makeViewModel(loadPersistedOperation: { _ in nil })

        await viewModel.loadPersisted(meetingId: meetingId)

        guard case .idle = viewModel.runState else {
            Issue.record("expected .idle, got \(viewModel.runState)")
            return
        }
    }

    @Test("loadPersisted does not override a live .running state (reentrancy guard)")
    func loadPersistedDoesNotOverrideRunningState() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let viewModel = makeViewModel(
            runOperation: { _, _, _, progress in
                progress(.preparingModels, 0.0)
                for await _ in gate {
                    break
                }
                return DiarizationService.RunResult(stampedRows: 0, unresolvedRows: 0, speakers: [])
            },
            // Would succeed if the guard were broken — proves the guard, not a missing operation.
            loadPersistedOperation: { _ in
                DiarizationService.PersistedDiarizationResult(
                    speakers: [DiarizationService.PersistedSpeaker(
                        speakerId: speakerId,
                        isAssigned: false,
                        speechSecs: 5.0
                    )],
                    stampedRows: 1, unresolvedRows: 0
                )
            }
        )
        viewModel.setExactCount(2)

        let runTask = Task { await viewModel.run(meetingId: meetingId, audioURL: audioURL) }
        while case .idle = viewModel.runState {
            await Task.yield()
        }

        await viewModel.loadPersisted(meetingId: meetingId)

        guard case .running = viewModel.runState else {
            Issue.record("loadPersisted must not clobber an in-flight .running state, got \(viewModel.runState)")
            return
        }

        gateContinuation.finish()
        await runTask.value
    }

    @Test("re-running after a reconstruction still runs the pipeline and stays idempotent")
    func rerunAfterReconstructStillRunsAndStaysIdempotent() async throws {
        let db = try await makeReconstructableDatabase()
        let service = DiarizationService(
            database: db, provider: FailingDiarizationProvider(), audioLoader: FailingAudioLoader()
        )
        let runSpy = CallSpy<Never>()
        let viewModel = makeViewModel(
            runOperation: { _, _, _, _ in
                await runSpy.record()
                return DiarizationService.RunResult(stampedRows: 1, unresolvedRows: 0, speakers: [])
            },
            loadPersistedOperation: { meetingId in
                try await service.loadPersisted(meetingId: meetingId)
            }
        )

        await viewModel.loadPersisted(meetingId: meetingId)
        guard case .reconstructed = viewModel.runState else {
            Issue.record("expected .reconstructed, got \(viewModel.runState)")
            return
        }

        viewModel.setExactCount(1)
        await viewModel.run(meetingId: meetingId, audioURL: audioURL)
        #expect(await runSpy.callCount == 1)
        guard case .succeeded = viewModel.runState else {
            Issue.record("expected .succeeded after re-run, got \(viewModel.runState)")
            return
        }

        await viewModel.run(meetingId: meetingId, audioURL: audioURL)
        #expect(await runSpy.callCount == 2)
        guard case .succeeded = viewModel.runState else {
            Issue.record("expected .succeeded after second re-run, got \(viewModel.runState)")
            return
        }
    }

    @Test("loadLikelyPeople populates honestly, empty on a throwing source")
    func loadLikelyPeoplePopulatesHonestly() async {
        let person1 = Person(id: "person-1", displayName: "Nia", isOwner: false, createdAt: Date(), updatedAt: Date())
        let person2 = Person(id: "person-2", displayName: "Sean", isOwner: false, createdAt: Date(), updatedAt: Date())
        let viewModel = makeViewModel(likelyPeopleOperation: { _ in [person1, person2] })

        await viewModel.loadLikelyPeople(inMeeting: meetingId)
        #expect(viewModel.likelyPeople.count == 2)

        let throwingViewModel = makeViewModel(likelyPeopleOperation: { _ in throw StubError() })
        await throwingViewModel.loadLikelyPeople(inMeeting: meetingId)
        #expect(throwingViewModel.likelyPeople == [])
    }

    @Test("neither loadPersisted nor loadLikelyPeople ever touches the confirm write path (I1)")
    func confirmRemainsOnlyWritePath() async {
        let confirmSpy = CallSpy<Never>()
        let viewModel = makeViewModel(
            confirmOperation: { _, _, _ in await confirmSpy.record() },
            loadPersistedOperation: { _ in
                DiarizationService.PersistedDiarizationResult(speakers: [], stampedRows: 0, unresolvedRows: 0)
            },
            likelyPeopleOperation: { _ in [] }
        )

        await viewModel.loadPersisted(meetingId: meetingId)
        await viewModel.loadLikelyPeople(inMeeting: meetingId)

        #expect(await confirmSpy.callCount == 0)
    }
}
