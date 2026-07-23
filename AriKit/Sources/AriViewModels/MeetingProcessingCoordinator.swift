//
//  MeetingProcessingCoordinator.swift — the post-recording generation pipeline (docs/plans/
//  swift-meeting-generation-flow.md, Track 2 §2). Owned by `AppEnvironment` (mount-independent,
//  like `RecordingSession`) so the pipeline survives navigation away from the recording page —
//  one active job at a time, mirroring the Rust incumbent's single pipeline.
//
//  Locked product decisions (plan, 2026-07-22): after a recording concludes, ALWAYS attempt
//  speaker identification — resolve a count hint (calendar/participants); if one exists, run
//  diarization automatically; if none exists, PAUSE and ask the user for a count
//  (`.needsSpeakerCount`) — the user may skip. Diarization failure is NON-BLOCKING (decision 3):
//  a failure is recorded honestly in `diarizationNote` and the pipeline continues to template +
//  summary regardless of what (if anything) diarization resolved — never strand a meeting with
//  no summary because clustering hiccuped; the manual "Identify speakers" sheet remains available
//  afterward to redo it. Summary generation itself honors the `summaryAutomatic` setting
//  (default ON when unset).
//
//  Headless (closure-injected), mirroring `SpeakerIdentificationViewModel`'s shape: progress is
//  bridged from the diarization service's `@Sendable (DiarizationPhase, Double) -> Void` callback
//  onto an `AsyncStream` consumed by a single `@MainActor` task, so every phase update lands on
//  `phase` in order before the underlying operation returns — deterministic for tests, no lost or
//  reordered updates from competing `Task { @MainActor }` hops.
//
//  Reentrancy (plan correction, locked with the owner 2026-07-22): `begin` proceeds when `phase`
//  is `.idle` OR a TERMINAL state (`.completed`/`.failed`) — starting a fresh pipeline and
//  resetting `activeMeetingID`/`diarizationNote`/`phase` — and only no-ops while a pipeline is
//  ACTIVELY running (`.identifyingSpeakers`/`.needsSpeakerCount`/`.selectingTemplate`/
//  `.summarizing`). A `.completed` phase from a PRIOR meeting must never permanently block a
//  later recording in the same session from ever processing.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingProcessingCoordinator {
    /// Honest pipeline phase (No-Fake-State): every value is real, never a fabricated progress
    /// step. `.failed` is reserved for pipeline-fatal errors only (summary generation failing
    /// outright, a rare case) — a non-fatal diarization failure is recorded in `diarizationNote`
    /// instead, and the pipeline continues past it to `.completed`.
    public enum Phase: Equatable {
        case idle
        case identifyingSpeakers(DiarizationPhase, Double)
        /// Paused for user input — the app presents the speaker-count prompt sheet.
        case needsSpeakerCount
        case selectingTemplate
        case summarizing
        case completed
        /// Terminal, benign: the pipeline finished without a summary for a reason that is not a
        /// fault — today only "the recording captured no speech, so there is nothing to
        /// summarize". Presented as a calm note, never as an error (a silent recording is a fact
        /// about the room, not a bug the user should be alarmed by).
        case skipped(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var activeMeetingID: MeetingID?
    /// Honest, non-fatal note when diarization was attempted and failed but the pipeline
    /// continued (decision 3). `nil` otherwise. Surfaced as a soft banner, never blocks.
    public private(set) var diarizationNote: String?

    /// The audio URL resolved for the meeting paused at `.needsSpeakerCount`, so
    /// `provideSpeakerCount` can resume the run without re-resolving it. `nil` outside that pause.
    private var pendingAudioURL: URL?

    /// The pipeline's own in-flight task: `begin`/`provideSpeakerCount`/`skipSpeakerIdentification`
    /// all await this so callers observe the full run's outcome before returning, and `cancel()`
    /// can interrupt it.
    private var runTask: Task<Void, Never>?
    /// Test-only synchronization hook (mirrors `SpeakerIdentificationViewModel.progressTask`):
    /// lets tests await the progress-consuming task deterministically instead of racing it.
    var progressTask: Task<Void, Never>?

    private let resolveAudioURLOperation: ResolveAudioURLOperation
    private let resolveHintOperation: ResolveHintOperation
    private let runDiarizationOperation: RunDiarizationOperation
    private let isAutoSummaryEnabledOperation: IsAutoSummaryEnabledOperation
    private let generateSummaryOperation: GenerateSummaryOperation
    private let speakerCountOperation: SpeakerCountOperation
    private let cancelSummaryOperation: CancelSummaryOperation
    /// Optional post-generation hook (the app wires it to `MeetingNotifications.summaryGenerated`).
    /// Called only after a summary ACTUALLY generated successfully, with that generation's real
    /// wall-clock duration — the notifier decides whether it was "long" enough to notify. `nil` in
    /// tests / when no notification stack is wired.
    private let notifySummaryGeneratedOperation: NotifySummaryGeneratedOperation?

    public typealias ResolveAudioURLOperation = @Sendable (_ meetingId: MeetingID) async -> URL?
    public typealias ResolveHintOperation = @Sendable (_ meetingId: MeetingID) async -> SpeakerCountHint?
    public typealias RunDiarizationOperation = @Sendable (
        _ meetingId: MeetingID,
        _ audioURL: URL,
        _ hint: SpeakerCountHint,
        _ progress: @escaping @Sendable (DiarizationPhase, Double) -> Void
    ) async throws -> Void
    public typealias IsAutoSummaryEnabledOperation = @Sendable () async -> Bool
    public typealias GenerateSummaryOperation = @Sendable (
        _ meetingId: MeetingID,
        _ speakerCount: Int?
    ) async throws -> Void
    public typealias SpeakerCountOperation = @Sendable (_ meetingId: MeetingID) async -> Int?
    public typealias CancelSummaryOperation = @Sendable (_ meetingId: MeetingID) async -> Void
    public typealias NotifySummaryGeneratedOperation = @Sendable (
        _ meetingId: MeetingID,
        _ elapsed: Duration
    ) async -> Void

    /// The only initializer — the app composition root (`AppEnvironment.bootstrap()`) assembles
    /// these closures directly from `diarizationService`/`speakerCountHintProvider`/`summaryRunner`/
    /// `database.settings`, so there is no separate "service-composing" convenience initializer
    /// (unlike `SpeakerIdentificationViewModel`, which wraps a single `DiarizationService`; this
    /// coordinator's closures each pull from a different collaborator).
    public init(
        resolveAudioURL: @escaping ResolveAudioURLOperation,
        resolveHint: @escaping ResolveHintOperation,
        runDiarization: @escaping RunDiarizationOperation,
        isAutoSummaryEnabled: @escaping IsAutoSummaryEnabledOperation,
        generateSummary: @escaping GenerateSummaryOperation,
        speakerCount: @escaping SpeakerCountOperation,
        cancelSummary: @escaping CancelSummaryOperation,
        notifySummaryGenerated: NotifySummaryGeneratedOperation? = nil
    ) {
        resolveAudioURLOperation = resolveAudioURL
        resolveHintOperation = resolveHint
        runDiarizationOperation = runDiarization
        isAutoSummaryEnabledOperation = isAutoSummaryEnabled
        generateSummaryOperation = generateSummary
        speakerCountOperation = speakerCount
        cancelSummaryOperation = cancelSummary
        notifySummaryGeneratedOperation = notifySummaryGenerated
    }

    // MARK: - Intents

    /// Starts the post-recording pipeline for `meetingId`. A no-op while a pipeline is ACTIVELY
    /// running for any meeting (`.identifyingSpeakers`/`.needsSpeakerCount`/`.selectingTemplate`/
    /// `.summarizing`); proceeds — resetting all per-run state — from `.idle` or any terminal
    /// state (`.completed`/`.skipped`/`.failed`), so a prior meeting's finished run never blocks
    /// this one.
    public func begin(meetingId: MeetingID) async {
        switch phase {
        case .identifyingSpeakers, .needsSpeakerCount, .selectingTemplate, .summarizing:
            return
        case .idle, .completed, .skipped, .failed:
            break
        }

        activeMeetingID = meetingId
        diarizationNote = nil
        pendingAudioURL = nil
        phase = .idle

        let task = Task { [weak self] in
            guard let self else { return }
            await runInitialSteps(meetingId: meetingId)
        }
        runTask = task
        await task.value
    }

    /// Resumes a paused `.needsSpeakerCount` run with the user's entered count hint, then
    /// continues straight through to template + summary. A no-op from any other phase.
    ///
    /// The `phase` write below happens SYNCHRONOUSLY, before the first `await` — closing a
    /// reentrancy window a naive "flip phase only inside the spawned task" version would leave
    /// open. The app's count-prompt sheet can plausibly call both this (its "Identify" action)
    /// and, via the dismiss-routes-to-skip binding, `skipSpeakerIdentification()` in the same UI
    /// turn; since MainActor work only interleaves at genuine suspension points (never mid a
    /// synchronous run), whichever call's synchronous prefix runs first flips `phase` away from
    /// `.needsSpeakerCount` before the other's guard can even be evaluated — so only one call
    /// ever proceeds, no matter the exact scheduling order.
    public func provideSpeakerCount(_ hint: SpeakerCountHint) async {
        guard case .needsSpeakerCount = phase, let meetingId = activeMeetingID, let audioURL = pendingAudioURL else {
            return
        }
        pendingAudioURL = nil
        phase = .identifyingSpeakers(.preparingModels, 0.0)
        let task = Task { [weak self] in
            guard let self else { return }
            await runSpeakerID(meetingId: meetingId, audioURL: audioURL, hint: hint)
        }
        runTask = task
        await task.value
    }

    /// Resumes a paused `.needsSpeakerCount` run WITHOUT running diarization — straight to
    /// template + summary (the user chose to skip). A no-op from any other phase. Same
    /// synchronous-phase-write reentrancy discipline as `provideSpeakerCount` above.
    public func skipSpeakerIdentification() async {
        guard case .needsSpeakerCount = phase, let meetingId = activeMeetingID else {
            return
        }
        pendingAudioURL = nil
        phase = .selectingTemplate
        let task = Task { [weak self] in
            guard let self else { return }
            await proceedToTemplateAndSummary(meetingId: meetingId)
        }
        runTask = task
        await task.value
    }

    /// Interrupts the in-flight pipeline, if any, and returns to `.idle`. Best-effort: cancels the
    /// underlying task (cooperative cancellation) and, if a summary generation is in flight, asks
    /// the injected `cancelSummary` operation to cancel it too (mirrors `SummaryRunner.cancel`).
    public func cancel() {
        runTask?.cancel()
        progressTask?.cancel()
        if case .summarizing = phase, let meetingId = activeMeetingID {
            let cancelOp = cancelSummaryOperation
            Task { await cancelOp(meetingId) }
        }
        phase = .idle
        activeMeetingID = nil
        diarizationNote = nil
        pendingAudioURL = nil
    }

    // MARK: - Pipeline

    private func runInitialSteps(meetingId: MeetingID) async {
        guard let audioURL = await resolveAudioURLOperation(meetingId) else {
            // No recording to diarize (Rust's "unavailable != failure") — skip speaker ID
            // entirely and go straight to template + summary.
            await proceedToTemplateAndSummary(meetingId: meetingId)
            return
        }
        guard let hint = await resolveHintOperation(meetingId) else {
            // No hint signal exists — pause for the user (the app presents the count prompt).
            pendingAudioURL = audioURL
            phase = .needsSpeakerCount
            return
        }
        await runSpeakerID(meetingId: meetingId, audioURL: audioURL, hint: hint)
    }

    /// Runs diarization, bridging its progress callback onto `phase` exactly like
    /// `SpeakerIdentificationViewModel.run` bridges onto `runState`. A thrown error is caught and
    /// recorded as an honest, non-fatal note (decision 3) — the pipeline always continues to
    /// template + summary afterward, whether diarization succeeded, failed, or was skipped.
    private func runSpeakerID(meetingId: MeetingID, audioURL: URL, hint: SpeakerCountHint) async {
        phase = .identifyingSpeakers(.preparingModels, 0.0)

        let (stream, continuation) = AsyncStream<(DiarizationPhase, Double)>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await (diarPhase, fraction) in stream {
                // A cancel() (which cancels this task and sets phase to .idle) must not be
                // clobbered by a progress item still draining out of the stream behind it.
                guard !Task.isCancelled else { continue }
                self?.phase = .identifyingSpeakers(diarPhase, fraction)
            }
        }
        progressTask = consumer

        do {
            try await runDiarizationOperation(meetingId, audioURL, hint) { diarPhase, fraction in
                continuation.yield((diarPhase, fraction))
            }
            continuation.finish()
            await consumer.value
        } catch is CancellationError {
            // A user-initiated `cancel()` aborts the WHOLE pipeline — it must never be recorded as
            // a diarization "failure" note (that would be dishonest — the user cancelled, nothing
            // failed) nor allowed to continue on to template + summary. `cancel()` already set
            // `phase = .idle`; just unwind.
            continuation.finish()
            await consumer.value
            return
        } catch {
            continuation.finish()
            await consumer.value
            diarizationNote =
                "Speaker identification didn't complete: \(UserFacingError.message(error)) " +
                "The summary was generated without speaker labels."
        }

        await proceedToTemplateAndSummary(meetingId: meetingId)
    }

    /// Template signal + summary generation, honoring `summaryAutomatic` (decision 2). Reaching
    /// this step never depends on how (or whether) speaker identification went — the honest
    /// `diarizationNote`, if any, was already recorded by `runSpeakerID` above.
    private func proceedToTemplateAndSummary(meetingId: MeetingID) async {
        // A `cancel()` that lands after speaker ID but before/at template selection unwinds here
        // too — `cancel()` already set `phase = .idle`, so never step on it with `.selectingTemplate`.
        if Task.isCancelled {
            return
        }
        phase = .selectingTemplate
        let count = await speakerCountOperation(meetingId)

        guard await isAutoSummaryEnabledOperation() else {
            // Manual generation stays available via `MeetingSummaryViewModel` regardless of this
            // setting (Track 1) — this pipeline simply doesn't auto-trigger it.
            phase = .completed
            return
        }

        phase = .summarizing
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await generateSummaryOperation(meetingId, count)
        } catch is CancellationError {
            // A user-initiated cancel is not a failure (mirrors `MeetingSummaryViewModel.generate`).
            phase = .idle
            return
        } catch LLMError.cancelled {
            phase = .idle
            return
        } catch LLMError.nothingToSummarize {
            // Benign, not a fault: the recording captured no speech. Terminal, calm, honest.
            phase = .skipped(UserFacingError.message(LLMError.nothingToSummarize))
            return
        } catch {
            phase = .failed(UserFacingError.message(error))
            return
        }
        let elapsed = clock.now - started
        phase = .completed
        // Fire the post-generation hook AFTER reaching the terminal `.completed` state, so a slow
        // notifier can never delay the UI's completion signal. The notifier itself decides whether
        // `elapsed` clears the "long summary" bar worth notifying about.
        await notifySummaryGeneratedOperation?(meetingId, elapsed)
    }
}
