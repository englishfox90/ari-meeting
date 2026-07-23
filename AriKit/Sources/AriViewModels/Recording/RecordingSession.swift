//
//  RecordingSession.swift — the app-wide recording brain (docs/plans/ari-recording-page.md §2.4,
//  §5, §7). Slice R1.
//
//  Owned above the recording page (by `AppEnvironment`, app target — R2), so recording keeps
//  running across navigation: the session's tasks are owned by this object, not by any view's
//  `.task` lifetime.
//
//  Explicit-intent-before-record (structural invariant, §7): capture is only ever reached through
//  an explicit user action. Constructing the session or rendering a view over it never touches
//  `CaptureService` — only `requestStart()` (the Record tap) does. When `requireConsent` is ON, an
//  extra confirmation gate sits in between (`requestStart` → `.consentPrompt` → `confirmConsent()`);
//  when OFF (default — private single-user tool, one-party jurisdiction) the Record tap is itself
//  the consent and goes straight to capture. Either way the sole trigger is a user-initiated tap,
//  never an automatic/silent start (`RecordingSessionTests`, consent-invariant cases).
//
//  No-Fake-State (§7): every failure path lands in `.failed(<real error string>)` — never a green
//  `.recording` phase over a graph that didn't actually start. The Meeting row is created only
//  AFTER `CaptureService.start()` actually succeeds (§5: "never a row for a recording that never
//  began").
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class RecordingSession {
    public enum Phase: Equatable {
        case idle
        case consentPrompt // BRAND.md §2 copy; the consent gate
        case starting // TCC prompts may be up; capture graph spinning up
        case recording(startedAt: Date) // live; transcript accumulating
        case stopping // end-of-input → drain finals → remux
        case saved(MeetingID)
        case failed(String) // honest, with the real error
    }

    public private(set) var phase: Phase = .idle
    /// Finalized, persisted transcript segments, in arrival order.
    public private(set) var segments: [Transcript] = []
    public private(set) var liveLevel: Float = 0
    public private(set) var micStatus: CaptureAvailability = .notDetermined
    public private(set) var systemStatus: CaptureAvailability = .notDetermined
    public private(set) var transcriberReadiness: TranscriberReadiness
    /// Set once the Meeting row exists (only after capture has actually started, §5).
    public private(set) var meetingId: MeetingID?
    /// The idle-screen title field's live value (plan §4.3 "R2"). A blank/whitespace-only value
    /// falls back to the honest "Untitled meeting" default at `confirmConsent()` — never a
    /// fabricated name. The view binds directly to this; it is not itself a `Phase`.
    public var pendingTitle: String = ""

    /// Whether `requestStart()` routes through the consent-before-record prompt (`.consentPrompt`)
    /// or straight to capture. Defaults OFF — the Record action is itself the explicit edge into
    /// capture for this private, single-user tool (see `SettingKey.recordingsRequireConsent`). The
    /// app sets this from the persisted setting at bootstrap and keeps it live via the Settings
    /// toggle's `onRecordingRequireConsentChanged` callback. When ON, the classic two-step gate
    /// (`requestStart` → `confirmConsent`) is restored intact.
    public var requireConsent: Bool = false

    /// Set by the Calendar page's "Start meeting" action before handoff (S7 Slice 3,
    /// `docs/plans/arikit-calendar-ui.md` §5), mirroring `pendingTitle`: consumed at meeting
    /// creation in `performStart()`, cleared there and by `reset()`. Visible to the idle screen
    /// as a removable "Will link to: <title>" chip (No-Fake-State — a stale intent must never
    /// silently link the wrong event); `eventTitle` exists ONLY for that chip's copy, never as a
    /// substitute for a real persisted link.
    public struct PendingCalendarLink: Equatable, Sendable {
        public var eventId: CalendarEventID
        public var eventTitle: String

        public init(eventId: CalendarEventID, eventTitle: String) {
            self.eventId = eventId
            self.eventTitle = eventTitle
        }
    }

    /// The Calendar page's pending link intent, if any. `nil` once consumed (a link written at
    /// meeting creation) or explicitly cleared by the user via the chip's ✕.
    public var pendingCalendarLink: PendingCalendarLink?

    public var isActive: Bool {
        switch phase {
        case .starting, .recording, .stopping:
            true
        case .idle, .consentPrompt, .saved, .failed:
            false
        }
    }

    private let database: AppDatabase
    /// Root directory under which each recording gets its own `<meetingID>/` folder (plan §5).
    /// Injectable so tests use a temp directory; the app passes the real Application Support path.
    private let recordingsRoot: URL
    private let makeCaptureService: @Sendable (URL) throws -> any CaptureService
    private let transcription: any LiveTranscriptionService
    private let clock: @Sendable () -> Date

    private var captureService: (any CaptureService)?
    private var segmentTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    /// The async continuation of `confirmConsentRequested()`. Internal (not `private`) so tests
    /// can await the start deterministically — mirrors `readinessProbeTask`.
    var startTask: Task<Void, Never>?
    /// Test-only synchronization hook for the init-time readiness probe below (`@testable`-only;
    /// not part of the plan's public surface). Lets headless tests await the probe deterministically
    /// instead of racing it with sleeps.
    var readinessProbeTask: Task<Void, Never>?
    /// Test-only synchronization hook for the init-time source-availability probe below
    /// (`@testable`-only). Lets headless tests await the probe deterministically instead of
    /// racing it with sleeps — mirrors `readinessProbeTask`.
    var sourceProbeTask: Task<Void, Never>?

    public init(
        database: AppDatabase,
        recordingsRoot: URL,
        makeCaptureService: @escaping @Sendable (URL) throws -> any CaptureService,
        transcription: any LiveTranscriptionService,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.recordingsRoot = recordingsRoot
        self.makeCaptureService = makeCaptureService
        self.transcription = transcription
        self.clock = clock
        // Honest placeholder — a real probe is still pending, never a fabricated "ready" (§7).
        transcriberReadiness = .unavailable(reason: "checking transcriber availability…")

        // Populate the idle-screen readiness readout (plan §4.3) without waiting for the user to
        // tap Record — `confirmConsent()` re-checks this authoritatively before it ever starts
        // capture, so a stale/racy value here can degrade the UI but can never green-light a
        // start the engine can't back.
        readinessProbeTask = Task { [weak self, transcription] in
            let readiness = await transcription.readiness()
            self?.transcriberReadiness = readiness
        }

        // Same idea for the idle screen's source-readiness rows (plan §4.3): probe a scratch
        // `CaptureService` instance (never started) just to read its honest `sourceStatus()`
        // before the user ever taps Record. `confirmConsent()` builds and starts its OWN,
        // freshly-folder-scoped instance and re-derives `micStatus`/`systemStatus`
        // authoritatively from that start — this probe can only degrade the idle-screen
        // readout, never green-light a start it can't back.
        sourceProbeTask = Task { [weak self, makeCaptureService, recordingsRoot] in
            guard let probe = try? makeCaptureService(recordingsRoot) else { return }
            let status = await probe.sourceStatus()
            self?.micStatus = status.mic
            self?.systemStatus = status.system
        }
    }

    // MARK: - Intents

    /// The explicit user edge into a recording (re-entrancy guarded — one live session at a time,
    /// mirrors the Rust single `RECORDING_FLAG`). With `requireConsent` OFF (default), tapping
    /// Record IS the consent, so this goes straight to capture (`idle -> starting`), mirroring the
    /// synchronous `.starting` flip of `confirmConsentRequested()`. With it ON, this only opens the
    /// consent gate (`idle -> consentPrompt`) and capture waits for `confirmConsent()`. A no-op
    /// from any non-`idle` phase.
    public func requestStart() {
        guard case .idle = phase else { return }
        if requireConsent {
            phase = .consentPrompt
        } else {
            phase = .starting
            startTask = Task { await performStart() }
        }
    }

    /// `consentPrompt -> idle`. A no-op from any other phase.
    public func cancelConsent() {
        guard case .consentPrompt = phase else { return }
        phase = .idle
    }

    /// The ONLY edge into `starting`/capture (consent-before-record, §7). `consentPrompt ->
    /// starting -> recording(startedAt:) | failed`. A no-op from any other phase — including a
    /// re-entrant call made while an earlier `confirmConsent()` is already in flight, since the
    /// phase is flipped to `.starting` synchronously before the first `await`.
    public func confirmConsent() async {
        guard case .consentPrompt = phase else { return }
        phase = .starting
        await performStart()
    }

    /// The synchronous consent edge for UI actions (review finding H3): flips to `.starting`
    /// BEFORE control returns to SwiftUI, so a sheet-dismiss `cancelConsent()` that runs after
    /// the Record tap is guaranteed to no-op — the sole edge into capture never rides on task
    /// scheduling order. The async start continues in a session-owned task.
    public func confirmConsentRequested() {
        guard case .consentPrompt = phase else { return }
        phase = .starting
        startTask = Task { await performStart() }
    }

    /// Everything after the `.starting` flip. Only reachable via the two consent edges above.
    private func performStart() async {

        // Re-check readiness authoritatively right before committing to a start — never trust a
        // stale init-time reading to green-light capture.
        let readiness = await transcription.readiness()
        transcriberReadiness = readiness
        guard case .ready = readiness else {
            phase = .failed(Self.readinessFailureReason(readiness))
            return
        }

        let newMeetingId = MeetingID(UUID().uuidString)
        let folder = recordingsRoot.appendingPathComponent(newMeetingId.rawValue, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create the recording folder: \(String(describing: error))")
            return
        }

        let service: any CaptureService
        do {
            service = try makeCaptureService(folder)
        } catch {
            phase = .failed("Could not set up capture: \(String(describing: error))")
            return
        }

        // Never a Meeting row for a recording that never began (§5) — `start()` is the gate.
        do {
            try await service.start()
        } catch {
            phase = .failed(String(describing: error))
            return
        }

        let status = await service.sourceStatus()
        micStatus = status.mic
        systemStatus = status.system

        let startedAt = clock()
        let trimmedTitle = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(
            id: newMeetingId,
            title: trimmedTitle.isEmpty ? "Untitled meeting" : trimmedTitle,
            createdAt: startedAt,
            updatedAt: startedAt,
            audioReference: LocalAudioReference(path: folder.path),
            transcriptionProvider: transcription.providerName
        )
        do {
            try await database.meetings.upsert(meeting)
        } catch {
            // The capture graph is already live here (review finding H1) — tear it down before
            // failing, or the mic/tap/saver would run orphaned until app quit with no way to
            // stop them (`stop()` guards on `.recording`).
            _ = try? await service.finish()
            phase = .failed("Could not save the meeting: \(String(describing: error))")
            return
        }

        // Consume the pending calendar link intent, if any (plan §5) — best-effort: a failed
        // link write must never fail the recording. Cleared either way, so a stale intent can
        // never silently re-attach to a later, unrelated meeting.
        if let pending = pendingCalendarLink {
            try? await database.calendarEvents.setManualLink(eventId: pending.eventId, meetingId: newMeetingId)
            pendingCalendarLink = nil
        }

        meetingId = newMeetingId
        captureService = service
        phase = .recording(startedAt: startedAt)

        // The transcription language chosen in Settings (defaults to the `"auto"` sentinel = system
        // language, which the provider resolves via `STTLocale.resolveRequestedLocale`).
        let language = await (try? database.settings.string(forKey: .transcriptionLanguage)) ?? nil
        beginLiveConsumption(service: service, meetingId: newMeetingId, language: language)
    }

    /// `recording -> stopping -> saved | failed`. A no-op from any other phase.
    public func stop() async {
        guard case .recording = phase else { return }
        phase = .stopping

        guard let service = captureService, let meetingId else {
            phase = .failed("No active capture to stop.")
            return
        }

        // Ends devices and remuxes in one call (the real `CaptureCoordinator.finish()`'s
        // contract, §2.1) — ending devices ends `mixedWindows()`, which lets the live
        // transcription stream drain its remaining finals and finish naturally.
        let finalURLResult: Result<URL, Error>
        do {
            let url = try await service.finish()
            finalURLResult = .success(url)
        } catch {
            finalURLResult = .failure(error)
        }

        // Await the segment task's natural completion — any segment already in flight when
        // `stop()` was called is persisted before we ever reach `.saved` (§6-L1-5).
        await segmentTask?.value
        levelTask?.cancel()
        segmentTask = nil
        levelTask = nil
        captureService = nil

        // Burst-drain safety net: re-upsert everything accumulated in memory in ONE batch
        // transaction (`TranscriptRepository.upsert([Transcript])`, §2.3/§5) — covers any
        // individual live-path write above that failed transiently.
        if !segments.isEmpty {
            do {
                try await database.transcripts.upsert(segments)
            } catch {
                phase = .failed("Could not save the transcript: \(String(describing: error))")
                return
            }
        }

        switch finalURLResult {
        case .success:
            do {
                if var meeting = try await database.meetings.find(meetingId) {
                    meeting.updatedAt = clock()
                    try await database.meetings.upsert(meeting)
                }
            } catch {
                phase = .failed("Could not finalize the meeting: \(String(describing: error))")
                return
            }
            phase = .saved(meetingId)
        case let .failure(error):
            phase = .failed(String(describing: error))
        }
    }

    /// `saved | failed -> idle`, for a fresh page visit. A no-op from any other phase.
    public func reset() {
        switch phase {
        case .saved, .failed:
            phase = .idle
            segments = []
            liveLevel = 0
            micStatus = .notDetermined
            systemStatus = .notDetermined
            meetingId = nil
            pendingTitle = ""
            pendingCalendarLink = nil
        case .idle, .consentPrompt, .starting, .recording, .stopping:
            break
        }
    }

    // MARK: - Live consumption

    private func beginLiveConsumption(
        service: any CaptureService,
        meetingId: MeetingID,
        language: String?
    ) {
        let transcription = transcription
        let database = database
        let windows = service.mixedWindows()
        let segmentsStream = transcription.transcribe(windows: windows, language: language)

        segmentTask = Task { [weak self] in
            do {
                for try await segment in segmentsStream {
                    guard let self else { return }
                    let transcript = TranscriptMapping.transcript(from: segment, meetingId: meetingId)
                    segments.append(transcript)
                    // Best-effort live write — a transient failure here must not truncate a live
                    // recording; the batch upsert in `stop()` is the durability safety net.
                    try? await database.transcripts.upsert(transcript)
                }
            } catch {
                // A live-transcription failure ends the segment stream early but must not tear
                // down an in-progress audio capture — `stop()` still runs its normal drain/finish
                // sequence over whatever segments were collected before the failure.
            }
        }

        levelTask = Task { [weak self] in
            for await level in service.liveLevel() {
                guard let self else { return }
                liveLevel = level
            }
        }
    }

    private static func readinessFailureReason(_ readiness: TranscriberReadiness) -> String {
        switch readiness {
        case .ready:
            "" // unreachable — guarded by the caller
        case let .downloadingAssets(progress):
            "The on-device speech model is still downloading (\(Int((progress * 100).rounded()))%)."
        case let .unavailable(reason):
            reason
        }
    }
}
