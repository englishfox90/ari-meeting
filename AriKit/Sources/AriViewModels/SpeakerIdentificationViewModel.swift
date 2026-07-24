//
//  SpeakerIdentificationViewModel.swift — the "Identify speakers" sheet's view model
//  (docs/plans/arikit-diarization.md §5 D9a, §6, §7).
//
//  Headless: no app-target dependency (swift-M4/swift-L4 — split out of the original single D9
//  slice). Owns none of `DiarizationService`'s persistence; it composes a hint source + the
//  service's `run`/`confirmSpeaker` operations (injected as closures, mirroring
//  `RecordingSession`'s `makeCaptureService` pattern) into `@Observable` UI state.
//
//  Two-mode count hint (H2, plan §6): the UI never exposes one ambiguous count field. An
//  "Exactly N" entry maps to `.exact` via `setExactCount`; a "Not sure / at most N" entry (or an
//  untouched calendar/participant prefill) maps to `.upperBound` via `setUncertainCount` — an
//  uncertain guess never silently becomes a forced-exact assertion.
//
//  Progress (plan §4): the service's `@Sendable (DiarizationPhase, Double) -> Void` progress
//  closure is bridged onto an `AsyncStream` consumed by a single `@MainActor` task, so every
//  phase update lands on `runState`/`progressHistory` in order before `run(_:audioURL:)` returns
//  — deterministic for tests, no lost or reordered updates from competing `Task { @MainActor }`
//  hops.
//
//  Consent-before-record is untouched by this file (invariant I6): `run` simply refuses to start
//  while `isRecording()` reports true — it opens no capture path of its own.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class SpeakerIdentificationViewModel {
    /// Honest run-state spine (No-Fake-State, invariant I2): idle until asked to run, real
    /// phase/fraction while running, the genuine result on success, the real error text on
    /// failure — never a fabricated "ready"/progress step.
    public enum RunState: Equatable {
        case idle
        case running(phase: DiarizationPhase, fraction: Double)
        case succeeded(DiarizationService.RunResult)
        /// Rebuilt from persisted rows without running the pipeline (speaker-retag-and-calendar-
        /// candidates.md §2 #2, decision 1) — never carries a fabricated `MatchDecision`
        /// score/tier (No-Fake-State), unlike `.succeeded`'s real fresh-run result.
        case reconstructed(DiarizationService.PersistedDiarizationResult)
        case failed(String)
    }

    public private(set) var runState: RunState = .idle
    /// Every phase update observed during the most recent run, in order — the UI-observable
    /// trail behind `runState`'s live snapshot (plan §5 D9a `progressPhasesReachUI`).
    public private(set) var progressHistory: [DiarizationPhase] = []
    /// The best available hint for the meeting, with provenance, or `nil` when no signal exists
    /// (honest absence — never a fabricated default). Set by `loadHint(for:)`.
    public private(set) var prefilledHint: ResolvedSpeakerHint?
    /// An explicit user entry from either count-hint mode (H2), overriding `prefilledHint` when
    /// present.
    public private(set) var userHint: SpeakerCountHint?
    /// The full assignable-person list for the sheet's "Assign person…" picker fallback list
    /// (plan §6). Honest empty array until `loadAssignablePeople()` succeeds — never fabricated.
    public private(set) var assignablePeople: [Person] = []
    /// The people likely in this meeting, resolved from calendar attendees ∪ linked participants
    /// (speaker-retag-and-calendar-candidates.md §2 #3). Honest empty until
    /// `loadLikelyPeople(inMeeting:)` succeeds / when none resolve — never fabricated.
    public private(set) var likelyPeople: [Person] = []

    /// Test-only synchronization hook (mirrors `RecordingSession.readinessProbeTask`): lets
    /// tests await the progress-consuming task deterministically instead of racing it.
    var progressTask: Task<Void, Never>?

    private let hintProvider: any SpeakerCountHintProviding
    /// Deliberately NOT `@Sendable` (D9b correction): this class is itself `@MainActor`, so
    /// `isRecording()` is always constructed and invoked on the main actor — dropping the
    /// unneeded `@Sendable` lets the app wire it straight to `@MainActor`-isolated state
    /// (`AppEnvironment.recordingSession?.isActive`) without a capture-Sendability error.
    private let isRecording: () -> Bool
    private let runOperation: RunOperation
    private let confirmOperation: ConfirmOperation
    private let assignablePeopleOperation: AssignablePeopleOperation
    private let assignmentSuggestionsOperation: AssignmentSuggestionsOperation
    private let loadPersistedOperation: LoadPersistedOperation
    private let likelyPeopleOperation: LikelyPeopleOperation

    typealias RunOperation = @Sendable (
        _ meetingId: MeetingID,
        _ audioURL: URL,
        _ hint: SpeakerCountHint,
        _ progress: @escaping @Sendable (DiarizationPhase, Double) -> Void
    ) async throws -> DiarizationService.RunResult

    typealias ConfirmOperation = @Sendable (
        _ speakerId: SpeakerID,
        _ personId: PersonID,
        _ meetingId: MeetingID
    ) async throws -> Void

    typealias AssignablePeopleOperation = @Sendable () async throws -> [Person]

    typealias AssignmentSuggestionsOperation = @Sendable (
        _ speakerId: SpeakerID
    ) async throws -> [(personId: PersonID, score: Float)]

    typealias LoadPersistedOperation = @Sendable (
        _ meetingId: MeetingID
    ) async throws -> DiarizationService.PersistedDiarizationResult?

    typealias LikelyPeopleOperation = @Sendable (
        _ meetingId: MeetingID
    ) async throws -> [Person]

    public convenience init(
        service: DiarizationService,
        hintProvider: any SpeakerCountHintProviding,
        isRecording: @escaping () -> Bool
    ) {
        self.init(
            hintProvider: hintProvider,
            isRecording: isRecording,
            runOperation: { meetingId, audioURL, hint, progress in
                try await service.run(meetingId: meetingId, audioURL: audioURL, hint: hint, progress: progress)
            },
            confirmOperation: { speakerId, personId, meetingId in
                try await service.confirmSpeaker(speakerId, as: personId, inMeeting: meetingId)
            },
            assignablePeopleOperation: {
                try await service.assignablePeople()
            },
            assignmentSuggestionsOperation: { speakerId in
                try await service.assignmentSuggestions(forSpeaker: speakerId)
            },
            loadPersistedOperation: { meetingId in
                try await service.loadPersisted(meetingId: meetingId)
            },
            likelyPeopleOperation: { meetingId in
                try await service.likelyAttendees(inMeeting: meetingId)
            }
        )
    }

    init(
        hintProvider: any SpeakerCountHintProviding,
        isRecording: @escaping () -> Bool,
        runOperation: @escaping RunOperation,
        confirmOperation: @escaping ConfirmOperation,
        assignablePeopleOperation: @escaping AssignablePeopleOperation = { [] },
        assignmentSuggestionsOperation: @escaping AssignmentSuggestionsOperation = { _ in [] },
        loadPersistedOperation: @escaping LoadPersistedOperation = { _ in nil },
        likelyPeopleOperation: @escaping LikelyPeopleOperation = { _ in [] }
    ) {
        self.hintProvider = hintProvider
        self.isRecording = isRecording
        self.runOperation = runOperation
        self.confirmOperation = confirmOperation
        self.assignablePeopleOperation = assignablePeopleOperation
        self.assignmentSuggestionsOperation = assignmentSuggestionsOperation
        self.loadPersistedOperation = loadPersistedOperation
        self.likelyPeopleOperation = likelyPeopleOperation
    }

    /// The hint that will actually drive a run: the user's explicit entry if any, else the
    /// prefill, else `nil` (honestly requires user input before `run` will proceed).
    public var resolvedHint: SpeakerCountHint? {
        userHint ?? prefilledHint?.hint
    }

    /// Whether `run` may currently be started — a hint exists AND no recording is in progress
    /// (plan §6: "Run button disabled until a hint exists in either mode"; invariant I6).
    public var canRun: Bool {
        resolvedHint != nil && !isRecording()
    }

    /// Loads the best available prefill from `hintProvider`. A throwing/absent source leaves
    /// `prefilledHint` honestly `nil` — never a fabricated default.
    public func loadHint(for meetingId: MeetingID) async {
        prefilledHint = try? await hintProvider.hint(for: meetingId)
    }

    /// "Exactly N" mode (H2) — the user asserts a known room size.
    public func setExactCount(_ n: Int) {
        userHint = .clampedExact(n)
    }

    /// "Not sure / at most N" mode (H2) — an uncertain guess. Always maps to `.upperBound`,
    /// never `.exact` — an uncertain count must never silently become a forced-precision
    /// assertion.
    public func setUncertainCount(_ n: Int) {
        userHint = .clampedUpperBound(n)
    }

    /// Clears the user's explicit entry, reverting `resolvedHint` to the calendar/participant
    /// prefill (if any).
    public func clearUserHint() {
        userHint = nil
    }

    /// Runs the full offline diarization pipeline for `meetingId`'s `audioURL`. Requires
    /// `canRun`; otherwise reports the honest reason in `runState` and never starts the
    /// underlying operation (invariants I4/I6).
    ///
    /// Reentrancy guard (D9a review fix): a second call while already `.running` is refused
    /// rather than starting a second consumer task that would interleave writes to
    /// `runState`/`progressHistory` with the first run's.
    public func run(meetingId: MeetingID, audioURL: URL) async {
        if case .running = runState {
            return
        }
        guard !isRecording() else {
            runState = .failed("Cannot identify speakers while recording is in progress.")
            return
        }
        guard let hint = resolvedHint else {
            runState = .failed("Enter a speaker count before identifying speakers.")
            return
        }

        progressHistory = []
        runState = .running(phase: .preparingModels, fraction: 0.0)

        let (stream, continuation) = AsyncStream<(DiarizationPhase, Double)>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await (phase, fraction) in stream {
                self?.runState = .running(phase: phase, fraction: fraction)
                self?.progressHistory.append(phase)
            }
        }
        progressTask = consumer

        do {
            let result = try await runOperation(meetingId, audioURL, hint) { phase, fraction in
                continuation.yield((phase, fraction))
            }
            continuation.finish()
            await consumer.value
            runState = .succeeded(result)
        } catch {
            continuation.finish()
            await consumer.value
            runState = .failed(String(describing: error))
        }
    }

    /// Loads the full assignable-person list for the sheet's "Assign person…" fallback list
    /// (plan §6). A throwing source leaves `assignablePeople` honestly empty — never fabricated.
    public func loadAssignablePeople() async {
        assignablePeople = await (try? assignablePeopleOperation()) ?? []
    }

    /// Ranked assign-picker suggestions for one speaker (plan §6, parity-M3). A throwing source
    /// returns an honestly empty array — never a fabricated suggestion.
    public func assignmentSuggestions(for speakerId: SpeakerID) async -> [(personId: PersonID, score: Float)] {
        await (try? assignmentSuggestionsOperation(speakerId)) ?? []
    }

    /// Confirm-before-enroll (plan §6): the single structural gate into
    /// `DiarizationService.confirmSpeaker` — nothing else in this view model writes a
    /// person↔voiceprint link (invariant I1). A failure surfaces honestly in `runState`.
    public func confirm(_ speakerId: SpeakerID, as personId: PersonID, inMeeting meetingId: MeetingID) async {
        do {
            try await confirmOperation(speakerId, personId, meetingId)
        } catch {
            runState = .failed(String(describing: error))
        }
    }

    /// Rebuilds the assignable list from persisted rows WITHOUT running the pipeline
    /// (speaker-retag-and-calendar-candidates.md §2 #2). Refuses to overwrite a live `.running`
    /// (same reentrancy guard as `run`). On success with rows, sets `.reconstructed`; when the
    /// meeting has never been diarized (`nil`), leaves `runState` untouched — it stays `.idle`
    /// (or whatever it already was), an explicit run is still required. On a thrown error, sets
    /// `.failed`.
    public func loadPersisted(meetingId: MeetingID) async {
        if case .running = runState {
            return
        }
        do {
            guard let result = try await loadPersistedOperation(meetingId) else {
                return
            }
            runState = .reconstructed(result)
        } catch {
            runState = .failed(String(describing: error))
        }
    }

    /// Loads the "likely in this meeting" candidates for the assign picker (speaker-retag-and-
    /// calendar-candidates.md §2 #3). A throwing source leaves `likelyPeople` honestly empty —
    /// never fabricated.
    public func loadLikelyPeople(inMeeting meetingId: MeetingID) async {
        likelyPeople = await (try? likelyPeopleOperation(meetingId)) ?? []
    }
}
