# Ari — New Meeting recording page (the native recording vertical's UI + app-wide session) — plan

> **STATUS: PLAN / not started.** Owner request 2026-07-21. This is the **user-facing spine of the
> already-sanctioned "native recording vertical"** (`docs/plans/arikit-native-shell.md` §0/§9-1,
> DECIDED 2026-07-20: order S0 → S8-lite → S6 → **S1–S5** → S7). S0 (app skeleton), S8-lite
> (import), S6 (read UI) and S1 (AriCapture pure DSP) are **landed**; this plan is the operative
> document for the remaining shell slices S2–S5 **plus** the recording page, the app-wide
> `RecordingSession`, and the persistent indicator. It supersedes nothing — it *executes* the
> shell plan's vertical with the concrete UI the owner asked for.

> **Owner directives (2026-07-21):**
> - **Reference, not copy-paste.** The frozen Rust app is a *behavior* reference (recording flow
>   outcomes: no-echo capture, per-segment live transcript, crash-safe checkpoints) — never a
>   line-for-line port. The design is native Swift: SpeechAnalyzer (not Whisper/Parakeet), actors
>   + AsyncStream (not the tokio loop), `@Observable` session (not React context), AVFoundation
>   encode (not the ffmpeg sidecar).
> - **Open decisions §9 resolved by recommendation (owner may override):** (1) ship finalized-only
>   first, volatile tail is optional slice R9; (2) **yes** mic-only fallback with an honest banner;
>   (3) `saved` = completion state with "Open meeting"; (4) indicator = floating bottom-leading
>   glass capsule over the detail pane.

## 1. Goal & seam

A dedicated recording page replacing the `.newMeeting` placeholder
(`Ari/UI/AppShell/RootSplitView.swift:78`) that (a) records mic + system audio, (b) renders the
transcript live as segments finalize, and (c) keeps recording across navigation — session state
owned **above** the page in `AppEnvironment`, with a persistent recording-red glass indicator in
the chrome to jump back.

**Seams.** Capture attaches at seam #1 (the PCM fork, `PCMWindow.swift:7` — the Q2 seam ported
from `audio/pipeline.rs:824`); STT attaches downstream via the already-landed live entrypoint
`SpeechTranscriberProvider.transcribe(liveInputs:language:)`
(`AriKit/Sources/AriKit/Engine/STT/SpeechTranscriberProvider.swift:216` — designed +
shape/cancellation-tested, **never fed by a real mic**; this plan feeds it). Persistence attaches
at the Store repositories (`AriKit/Sources/AriKit/Store/Repositories/`).

**Target-side confirmation (principle 8).** Everything lands Swift-side. The Rust app is frozen;
its recording flow (`audio/recording_manager.rs`, `pipeline.rs`, `transcription/worker.rs`) is
the behavior-parity reference for the capture port and is never edited. The *page + app-wide
session + indicator* are net-new Swift host code (no Rust equivalent to port — the Tauri host's
React `RecordingStateContext` is the *shape* reference only). This is a port + host work already
mandated to land here — it proceeds.

**WIP check.** One vertical, already gated by the orchestrator per the shell plan's DECIDED block.
No second phase opens. Calendar (S7), diarization (3.5), Ask, block editor stay out.

## 2. Module boundaries & public surface

Dependency direction (unchanged): `AriKit` ← `AriCapture`, `AriKit` ← `AriViewModels`, app target
consumes all three. `AriViewModels` gains **no** `AriCapture` dependency — the session sees
capture and STT only through protocols it defines, so it stays headless-testable
(`AriKit/Package.swift:67-74`) and iOS-clean (Phase 6 supplies mic-only conformers).

### 2.1 `AriCapture` — the live-device classes (shell plan §4, slices S2–S4)

New files (all `#if os(macOS)`; the existing S1 files — `Resampler`, `AudioMixer`, `AACRecorder`,
`IncrementalSaver`, `SpeechVAD` — are consumed, not modified):

```swift
/// AVAudioEngine mic capture → 48 kHz mono f32 (shell §4.2). Handles device churn via
/// AVAudioEngineConfigurationChange (stop → re-read hardware format → rebuild converter → restart).
public actor MicrophoneCapture {
    public init()
    /// Starts the engine; the tap uses inputNode.outputFormat(forBus: 0) (never a forced format).
    /// Emitted samples are already resampled to 48 kHz mono via Resampler.
    public func start() async throws -> AsyncStream<PCMWindow>     // source == .microphone
    public func stop() async
    /// Honest readiness: current TCC state + engine-running. Never fabricated.
    public func availability() -> CaptureAvailability
}

/// Core Audio process tap → private aggregate device → IOProc (shell §4.1; port of
/// core_audio.rs:91-133 incl. the NO-sub-device-list echo fix, behavior-verbatim).
public actor SystemAudioTap {
    public init()
    public func start() async throws -> AsyncStream<PCMWindow>     // source == .system
    public func stop() async
    /// Denial yields silence at the CoreAudio layer (permissions.rs:18-24) — this surfaces it
    /// honestly: .unavailable(reason:) when the tap produces no signal / creation fails.
    public func availability() -> CaptureAvailability
}

public enum CaptureAvailability: Sendable, Equatable {
    case ready
    case notDetermined                 // TCC prompt will fire on start
    case unavailable(reason: String)   // denied / no device / tap creation failed — honest
}

/// The Swift AudioPipeline::run() (shell §4.3). Owns ring-buffer windowing, the pre-mix PCM fork,
/// mixing, live level, and feeding IncrementalSaver. Never does inference on its loop (Q2 rule).
public actor CaptureCoordinator {
    public struct Config: Sendable {
        public var windowDuration: Double = 0.6          // ~600 ms, ← pipeline.rs
        public var meetingFolder: URL                     // owns <folder>/.checkpoints/ creation
        public var micEnabled: Bool
        public var systemEnabled: Bool
    }
    public init(config: Config, microphone: MicrophoneCapture, systemTap: SystemAudioTap) throws

    /// Starts devices + windowing + incremental saving. Throws honestly if NEITHER source starts.
    public func start() async throws
    /// Stops devices, flushes the saver, remuxes checkpoints → returns the final .m4a URL.
    public func finish() async throws -> URL

    /// Mixed 48 kHz mono windows for STT. Bounded, DROP-OLDEST (.bufferingNewest) — a slow
    /// consumer can never stall the hot path; a dropped window is silence, never invented audio.
    public func mixedWindows() -> AsyncStream<PCMWindow>
    /// Pre-mix fork (mic + system separate) — the F1/diarization seam, published now, unused v1.
    public func forkedWindows() -> AsyncStream<PCMWindow>
    /// Peak-hold live level for meters/HUD (← live_level.rs). Lock-free publish.
    public func liveLevel() -> AsyncStream<Float>
    /// Honest per-source status (drives the "System audio unavailable" banner).
    public func sourceStatus() -> (mic: CaptureAvailability, system: CaptureAvailability)
}
```

VAD placement (shell §9-3): **v1 sends raw mixed windows straight to SpeechTranscriber** — it
segments internally (arikit-stt.md §1) and the landed live path already proved the shape. The S1
`SpeechVAD` stays available as the fallback pre-filter if live quality/load regresses (recorded as
a risk, §9). No decision blocker.

### 2.2 `AriKit` Engine/STT — the join adapter (additive; shell §5 / §9-4: adapter is Engine-side)

One new file `Engine/STT/AnalyzerInputAdapter.swift`:

```swift
public enum AnalyzerInputAdapter {
    /// PCMWindow → AVAudioPCMBuffer (48 kHz mono float32) → AnalyzerInput, as a lazy mapped
    /// AsyncSequence. Empty windows are skipped (honest gap == silence, never a fabricated
    /// buffer). Uses SpeechAnalyzer.bestAvailableAudioFormat + AVAudioConverter only if the
    /// transcriber's preferred format differs (Transcribe.swift:257-294 pattern).
    public static func analyzerInputs(
        from windows: AsyncStream<PCMWindow>
    ) -> some AsyncSequence<AnalyzerInput, Never> & Sendable
}
```

`TranscriptionProvider` (`Engine/STT/TranscriptionProvider.swift:51`) is **not modified** in v1
(finalized-segments-only live stream). Volatile-text surfacing is the optional R9 slice (§9-1).

### 2.3 `AriKit` Store — the deferred batch write (arikit-stt.md §11-6, explicitly assigned to 3.2 = now)

```swift
// TranscriptRepository (additive):
public func upsert(_ transcripts: [Transcript]) async throws   // one dbWriter.write transaction
```

No schema change. No other Store edits.

### 2.4 `AriViewModels` — `RecordingSession` (the app-wide brain) + seam protocols

```swift
/// Abstracts the capture graph so the session tests headlessly and never imports AriCapture.
public protocol CaptureService: Sendable {
    func start() async throws
    func finish() async throws -> URL                       // final .m4a
    func mixedWindows() -> AsyncStream<PCMWindow>
    func liveLevel() -> AsyncStream<Float>
    func sourceStatus() async -> (mic: CaptureAvailability, system: CaptureAvailability)
}

/// Abstracts STT so the session never imports Speech (AnalyzerInput stays out of this module).
public protocol LiveTranscriptionService: Sendable {
    var providerName: String { get }
    /// nil availability reason == ready. Honest: asset-download / unavailable states pass through.
    func readiness() async -> TranscriberReadiness
    func transcribe(
        windows: AsyncStream<PCMWindow>, language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

public enum TranscriberReadiness: Sendable, Equatable {
    case ready(locale: String)
    case downloadingAssets(progress: Double)   // real AssetInventory progress, never invented
    case unavailable(reason: String)
}

@MainActor @Observable
public final class RecordingSession {
    public enum Phase: Equatable {
        case idle
        case consentPrompt                     // BRAND.md §2 copy; the consent gate
        case starting                          // TCC prompts may be up; capture graph spinning up
        case recording(startedAt: Date)        // live; transcript accumulating
        case stopping                          // end-of-input → drain finals → remux
        case saved(MeetingID)
        case failed(String)                    // honest, with the real error
    }

    public private(set) var phase: Phase = .idle
    public private(set) var segments: [Transcript] = []      // finalized, persisted, in order
    public private(set) var liveLevel: Float = 0
    public private(set) var micStatus: CaptureAvailability = .notDetermined
    public private(set) var systemStatus: CaptureAvailability = .notDetermined
    public private(set) var transcriberReadiness: TranscriberReadiness
    public private(set) var meetingId: MeetingID?            // set once the row exists
    public var isActive: Bool                                 // recording || starting || stopping

    public init(
        database: AppDatabase,
        makeCaptureService: @escaping @Sendable (URL) throws -> any CaptureService,  // folder in
        transcription: any LiveTranscriptionService,
        clock: @escaping @Sendable () -> Date = { Date() }
    )

    public func requestStart()                 // idle → consentPrompt (user tapped Record)
    public func confirmConsent() async         // consentPrompt → starting → recording | failed
    public func cancelConsent()                // consentPrompt → idle
    public func stop() async                   // recording → stopping → saved | failed
    public func reset()                        // saved/failed → idle (new page visit)
}
```

Transition rules (encoded as tests, §6): `confirmConsent` is the **only** edge into `starting`;
`starting → recording` only after `CaptureService.start()` returns **and** the Meeting row is
written; any start failure → `failed` with the underlying error (never a green page over a dead
graph). `stop()` is legal only from `recording`. Re-entrancy: `requestStart` while `isActive` is
a no-op (one live session per app — mirrors the Rust single `RECORDING_FLAG`).

### 2.5 `Ari` app target

- `Ari/Capture/LiveCaptureService.swift` — `CaptureService` conformer wrapping
  `CaptureCoordinator` + `MicrophoneCapture` + `SystemAudioTap` (thin glue, per shell §2.1
  "`Capture/` thin app-side glue only").
- `Ari/Capture/SpeechLiveTranscriptionService.swift` — `LiveTranscriptionService` conformer
  composing `AnalyzerInputAdapter` + `SpeechTranscriberProvider` + `SpeechAssetManager`
  (readiness = real `isAvailable`/`areAssetsInstalled`/install progress).
- `Ari/UI/NewMeeting/RecordingView.swift` — the page (§4.3).
- `Ari/UI/NewMeeting/ConsentSheet.swift` — stock `.sheet`, zero custom background (Liquid Glass
  v2 checklist), copy verbatim from BRAND.md §2: *"Record this meeting? Everyone on the call
  should know they're being recorded."* Primary action "Record" = **recording-red glass** button
  (`.marginalia(.recording, .large)`); secondary "Cancel" quiet.
- `Ari/UI/AppShell/RecordingIndicator.swift` — the chrome pill (§4.4).
- `AppEnvironment` gains `private(set) var recordingSession: RecordingSession?` constructed at
  `.ready` (needs `database`); `RootSplitView` `.newMeeting` case → `RecordingView(session:)`.
- `Ari.entitlements` + Info.plist: add `com.apple.security.device.audio-input` and the manual
  `NSAudioCaptureUsageDescription` key (the entitlements file already stubs this at
  `Ari/Ari.entitlements:7`; `NSMicrophoneUsageDescription` already set,
  `project.pbxproj:207`).

## 3. Concurrency & isolation (Swift 6 strict; no `@unchecked Sendable`)

- **Actor ownership of the capture graph:** `MicrophoneCapture`, `SystemAudioTap`,
  `CaptureCoordinator` are actors. Device callbacks (AVAudioEngine tap block, CoreAudio IOProc)
  run on realtime threads and must not `await`: they push into a lock-free ring / yield to an
  `AsyncStream.Continuation` (`.bufferingNewest(n)`) — the continuation's `yield` is
  synchronous and non-blocking, the exact `recording_sender` fork discipline
  (`pipeline.rs:887-895` / Q2). Windowing/mixing runs on the coordinator's executor, never on
  the callback thread. **Nothing on the hot path awaits STT, disk, or the DB.**
- **PCM flow:** callbacks → ring → coordinator loop → (a) fork stream (drop-oldest), (b) mix →
  mixed stream (drop-oldest) → `AnalyzerInputAdapter` → `SpeechTranscriberProvider` live path
  (which already forwards non-blocking into its internal analyzer stream,
  `SpeechTranscriberProvider.swift:283-290`), and (c) mix → `IncrementalSaver` (an actor;
  `addSamples` awaited from the coordinator loop, not the callback — file I/O amortized at 30 s
  checkpoints). The saver write is the one awaited consumer; if a checkpoint encode ever stalls,
  windows still fork/mix because the saver is fed via its own bounded stream, same drop-oldest
  posture (a dropped save window is real data loss and is **logged honestly**, never silently
  smoothed — expected to be unreachable in practice at 30 s cadence).
- **`RecordingSession` is `@MainActor`** (view state). It spawns one structured `Task` per
  recording that: consumes the finalized-segment stream, appends to `segments`, and batches DB
  writes (§5). `stop()` cancels nothing mid-flight blindly — it stops capture (ending the window
  stream → adapter sequence ends → provider signals true end-of-input → analyzer finalizes →
  remaining finals drain), then awaits the segment task's natural completion, then
  `CaptureService.finish()` remux. Hard-cancel (app quit mid-recording) relies on structured
  cancellation: the provider's `onTermination` cancels its outer task
  (`SpeechTranscriberProvider.swift:212-215`); checkpoints on disk are the crash-recovery story.
- **Device churn (AirPods):** handled entirely inside `MicrophoneCapture`
  (`AVAudioEngineConfigurationChange` → stop/rebuild-converter/restart, shell §4.2). The session
  observes nothing but a transient status change; recording continues. The Bluetooth resample
  distortion is a macOS artifact — not "fixed" (coding-conventions.md).
- **Sendable boundaries:** everything crossing actors is a value type (`PCMWindow`,
  `TranscriptionSegment`, `Transcript`, `CaptureAvailability`, `URL`). No shared mutable state.

## 4. App-wide state design

### 4.1 Ownership
`AppEnvironment` (already the `@Observable` root, `AppEnvironment.swift:16-18`) owns the single
`RecordingSession`. The page **never** owns capture state — navigating away destroys only the
view; the session's tasks keep running (they're owned by the session object, not `.task` view
lifetime). **Rule for implementers: no `.task`-scoped work in `RecordingView` may be load-bearing
for the recording** — the view only *renders* session state and forwards intents.

### 4.2 Lifecycle
`idle → consentPrompt → starting → recording(startedAt) → stopping → saved(MeetingID) | failed`
(§2.4). `saved` shows a completion state with "Open meeting" (pushes `MeetingID` onto the
existing `NavigationPath` via the shell's `navigationDestination(for: MeetingID.self)`,
`RootSplitView.swift:50`) and "New recording" (`reset()`).

### 4.3 The page (`RecordingView`)
Marginalia + Liquid Glass v2 checklist throughout (`MarginaliaCanvasWash` ground; content on
paper; stock components):
- **Idle:** title field (default honest "Untitled meeting" placeholder, not a fabricated name),
  source readiness rows (mic / system audio — real `CaptureAvailability`, including
  `unavailable(reason:)` in warm error ink with symbol, never color alone), transcriber readiness
  (honest `downloadingAssets(progress:)` with the framework's real fraction — never an invented
  percentage; `unavailable` states the reason and disables Record). THE primary action = **Record**,
  recording-red glass capsule (`.glassEffect(.regular.tint(recordingRed).interactive(), in: Capsule())`),
  the one Signal on the page.
- **consentPrompt:** the stock sheet (§2.5).
- **recording:** elapsed time derived from `startedAt` via `TimelineView(.periodic(...))` — real
  clock, never an accumulated counter that can drift; live level meter driven by
  `liveLevel` (real signal — animation of real state is sanctioned, BRAND.md §9); the live
  transcript list (finalized `Transcript` segments on paper, auto-scroll pinned to tail unless
  the user scrolls up); honest banners for degraded sources ("System audio unavailable — recording
  microphone only."). **Stop** = the recording-red action while live (the Record button morphs;
  still one Signal).
- **stopping:** "Finishing — saving audio and final transcript." with a real indeterminate spinner
  (no fake percent).
- **failed:** the real error + the decisive recovery action where known (BRAND.md §2 error voice).

### 4.4 The persistent indicator
- **Where:** a floating glass capsule over the **detail pane**, placed with
  `.safeAreaInset(edge: .bottom, alignment: .leading)` at the `NavigationStack` level in
  `RootSplitView.readyShell` — visible in every section and pushed detail screen. **Hidden when
  `selectedSection == .newMeeting`** (the page already carries the Signal; two red glass elements
  would double-spend the budget).
- **What:** recording-red **tinted glass** capsule (this *is* the live-capture Signal, Liquid
  Glass v1 rule 8): a dot + "Recording" + elapsed (same `startedAt`-derived clock) + the meeting
  title (truncated). Labels in `.canvas` on-fill ink. Click → `selectedSection = .newMeeting`
  (the existing `onChange` resets `path`, landing on the live page —
  `RootSplitView.swift:61-63`). Shown only while `session.isActive`; during `stopping` it reads
  "Finishing…" honestly. Never rendered when not recording (recording-red exclusivity).
- Additionally, the sidebar's "New meeting" primary button (`SidebarView.swift:240`) is disabled
  (or relabeled "Recording…", quiet) while `isActive` — one live session at a time.

### 4.5 Re-attach
Trivial by construction: `RecordingView` takes the session and renders `phase`/`segments`. A
Lane-2 checklist item verifies no observable glitch (scroll position may reset; acceptable v1).

## 5. Persistence (repositories only; single DB owner)

- **Meeting row created at `starting → recording`** (after the capture graph actually started —
  never a row for a recording that never began): `MeetingRepository.upsert` with fresh
  `MeetingID`, title, `createdAt/updatedAt = now`,
  `audioReference = LocalAudioReference(path: <folder>)`,
  `transcriptionProvider = transcription.providerName` (provenance, `Meeting.swift:26`).
- **Meeting folder:** `~/Library/Application Support/com.arivo.ari/recordings/<meetingID>/`,
  created by the app (`AppEnvironment`-style path resolution — the Store never touches
  FileManager); `.checkpoints/` created before `IncrementalSaver.init` (it requires existence,
  `IncrementalSaver.swift:74-76`). Final audio: `<folder>/audio.m4a` (48 kHz mono AAC-LC 192k,
  `AACRecorder.swift:17-18`), remuxed from checkpoints on `finish()`.
- **Transcript segments — finalized only, never volatile.** The session maps each finalized
  `TranscriptionSegment → Transcript` via the landed pure `TranscriptMapping` (fresh ID,
  `speakerId = nil`, MM:SS label) and flushes via the new
  `TranscriptRepository.upsert([Transcript])` in small batches (flush on each finalized segment
  v1 — write volume is trivial; the batch API exists for burst-drain at stop). Segments are
  therefore already durable if the app dies mid-recording.
- **On `saved`:** update `Meeting.updatedAt`; `IncrementalSaver.finalize` remux; checkpoint
  cleanup per the landed semantics.
- **Crash recovery (R8):** at `bootstrap()`, scan `recordings/*/.checkpoints/` for orphans; if
  found, remux to `audio.m4a`, keep the already-persisted transcript rows, and surface an honest
  one-line banner ("A recording was interrupted; audio up to the last checkpoint was recovered.").
  No fake "fully recovered" claim — the tail past the last checkpoint is genuinely lost and the
  copy says so.
- Capture (`AriCapture`) writes **zero** DB rows (shell §6.1). One `AppDatabase`, one process.

## 6. Acceptance tests

### Lane 1 — headless `swift test` (agent-runnable; written first, red → green)

`AriViewModelsTests/RecordingSessionTests` (stub `CaptureService` + `StubTranscriptionProvider`-backed stub `LiveTranscriptionService`, `AppDatabase.makeInMemory`, injected clock):
1. **State machine:** every legal transition; illegal ones no-op (`stop()` from idle;
   `requestStart()` while active; double `confirmConsent`).
2. **Consent invariant:** `CaptureService.start()` is called **only** downstream of
   `confirmConsent()`; constructing the session, rendering, `requestStart()` alone never start
   capture (spy service asserts zero calls).
3. **Live accumulation:** canned segments → `segments` appear in order; each is persisted (read
   back via `TranscriptRepository.forMeeting`); Meeting row exists with correct
   `audioReference`, `transcriptionProvider` provenance.
4. **Start failure honesty:** capture-start throw → `failed(<real error>)`, no Meeting row left
   live (created-then-soft-deleted or never created), no fake `recording` phase.
5. **Stop drains:** segments still in flight at `stop()` are persisted before `saved`; `saved`
   carries the right `MeetingID`; final URL from `finish()` recorded.
6. **Degraded-source honesty:** system `unavailable` + mic `ready` → recording proceeds with
   `systemStatus` surfaced; both unavailable → start fails honestly.
7. **Transcriber readiness pass-through:** `downloadingAssets(0.42)` renders as 0.42, never
   rounded up to done; `unavailable` blocks Record.
8. **Elapsed derivation:** injected clock → elapsed is `now − startedAt` (no drift counter).

`AriKitTests/Engine/STT/AnalyzerInputAdapterTests`: PCMWindow→buffer sample fidelity (float
equality on fixture windows), 48 kHz mono format, empty window skipped (no fabricated buffer),
lazy/non-blocking consumption with a slow consumer.

`AriKitTests/Store/TranscriptRepositoryBatchTests`: `upsert([Transcript])` atomicity (mid-batch
failure rolls back), ordering, idempotent re-upsert.

`AriCaptureTests/CaptureCoordinatorTests` (synthetic source streams — no devices): ~600 ms
windowing; fork emits mic+system **separate before** mix; mixed == `AudioMixer` result;
drop-oldest under a fake slow consumer (producer never stalls — the `PCMWindowContractTests`
promise, now against the real coordinator); saver fed every mixed window.

`AriCaptureTests` (existing S1 suites stay green — regression gate).

### Lane 2 — signed `.app` + human TCC (NOT agent-closeable; checklist per slice, shell §7)

1. Mic grant → record 30 s speech → live transcript appears; `.m4a` valid, audible.
2. System-audio grant → play known audio → present in recording; **no echo** (sub-device-list fix).
3. Deny system audio → honest "System audio unavailable" (never fake green); mic-only proceeds.
4. **Navigate away & back** mid-recording: indicator appears (red glass, elapsed live), other
   screens fully usable, click returns to the live page, transcript intact, recording never
   glitched. Indicator absent on the recording page itself.
5. AirPods churn mid-recording: connect + disconnect; no crash, capture continues, transcript
   resumes.
6. Kill the app mid-recording → relaunch → recovery banner; recovered audio plays; persisted
   transcript rows present.
7. **Long recording > 60 min** (the S2-caveat gate, shell §7): no truncation
   (`segments.last.end ≈` real `AVAudioFile` duration), checkpoints/remux at scale.
8. **Dual-run (principle 2):** record the same source scenario on the frozen Rust app and Ari;
   compare audio (level, duration, no echo) and transcript coverage — Swift meets or beats.
9. Visual: light/dark, Reduce Transparency/Motion; Signal budget (one red element per screen);
   consent copy verbatim.

## 7. Invariants preserved

- **Consent-before-record:** structural — `confirmConsent()` is the only edge into capture; test
  §6-L1-2; BRAND consent copy; F5 (calendar prompt) out of scope and unaffected.
- **No-Fake-State:** honest `CaptureAvailability` / `TranscriberReadiness` / real asset progress /
  real-clock elapsed / dropped-window-is-silence / crash-recovery copy admits tail loss /
  `failed` shows the real error. Volatile text (if R9 lands) renders visibly provisional and is
  **never persisted**.
- **Recording-red exclusivity:** red glass only while live (page action + indicator, mutually
  exclusive per screen); sidebar "New meeting" stays accent (already correct,
  `SidebarView.swift:237-239`); error states use warm error ink, never red.
- **Repositories-only / single-DB-owner:** all writes via `MeetingRepository` /
  `TranscriptRepository`; `AriCapture` writes no rows; one `AppDatabase`.
- **Recall safety shell:** untouched (Recall/Engine, already ported with tests).
- **Hot-path rule (Q2):** no inference/blocking on the capture loop — encoded in coordinator
  design + drop-oldest tests.

## 8. Slices (each independently green; ordered)

| # | Slice | Contents | Gate |
|---|-------|----------|------|
| R1 | Session core + seams | `CaptureService`/`LiveTranscriptionService`/`TranscriberReadiness` protocols, `RecordingSession`, `TranscriptRepository.upsert([Transcript])`, `AnalyzerInputAdapter` | **Lane 1 — agent-closeable** |
| R2 | Page UI on stubs | `RecordingView` + `ConsentSheet` + `AppEnvironment.recordingSession` + `.newMeeting` wiring; app ships honest "Microphone capture isn't built yet" readiness until R3 (real availability = `unavailable`) | Lane 1 + visual Lane 2 (light) — agent-closeable except visual sign-off |
| R3 | `MicrophoneCapture` (shell S2) | + entitlement/Info.plist keys; wire `LiveCaptureService` mic-only | **Lane 2** (checklist 1, 5-lite) |
| R4 | `SystemAudioTap` (shell S3) | echo fix behavior-verbatim | **Lane 2** (2, 3) |
| R5 | `CaptureCoordinator` + save (shell S4) | windowing/fork/mix/level + `IncrementalSaver`/`AACRecorder` wiring; coordinator Lane-1 suite | Lane 1 (coordinator) + **Lane 2** end-to-end `.m4a` |
| R6 | STT join (shell S5) | `SpeechLiveTranscriptionService` live; first real live transcript | **Lane 2** (1 full) |
| R7 | Persistent indicator + navigation | `RecordingIndicator`, hide-on-page, sidebar button gating | Lane 1 (isActive logic) + **Lane 2** (4) |
| R8 | Crash recovery | orphan scan at bootstrap + remux + honest banner | Lane 1 (detection on fixture dirs) + **Lane 2** (6) |
| R9 | *(optional, §9-1)* volatile tail | additive provider surface + secondary-ink rendering | Lane 1 shape + **Lane 2** |
| Rf | Vertical close-out | long recording (7), dual-run (8), full visual pass (9) | **Human-gated** |

Lane-2 slices run through the signed bundle with the agent driving via XcodeBuildMCP and the
human granting TCC once.

## 9. Open decisions — RESOLVED by recommendation (owner may override; see header)

1. **Volatile transcript text (R9)?** Ship R1–R8 finalized-only (matches the frozen Rust app's
   per-VAD-segment cadence); R9 later as an **additive** `LiveTranscriptionUpdate` stream
   (`.volatile(String)` / `.finalized(segment)`), rendered as one trailing run in `inkSecondary`
   (visibly provisional), replaced on finalization, never persisted.
2. **Mic-only fallback when the system tap is denied/unavailable?** **Yes** — proceed with an
   explicit "System audio unavailable — recording microphone only." banner. Encoded in §6-L1-6.
3. **Where `saved` lands:** completion state with "Open meeting" (lets the user title-edit first).
4. **Indicator placement:** bottom-leading floating glass capsule over the detail pane
   (glass-over-chrome, safeAreaInset per Liquid Glass v2).

## Sources / grounding

`docs/plans/arikit-native-shell.md` (§2-§11), `docs/plans/arikit-stt.md` (§2-§11),
`AriKit/Sources/AriKit/Capture/PCMWindow.swift`, `AriKit/Sources/AriCapture/*` (S1 landed),
`AriKit/Sources/AriKit/Engine/STT/SpeechTranscriberProvider.swift:216-290` (live path),
`AriKit/Sources/AriKit/Store/Repositories/{Meeting,Transcript}Repository.swift`,
`AriKit/Sources/AriKit/Models/{Meeting,Transcript}.swift`, `Ari/App/AppEnvironment.swift`,
`Ari/UI/AppShell/{RootSplitView,SidebarView,SidebarSection}.swift`, `Ari/Ari.entitlements:7`,
`brand/BRAND.md` §2/§9 (consent copy `:47`, recording-red rules `:94-97,:195`),
`docs/plans/liquid-glass-adoption.md` v2 checklist, `AriKit/Package.swift` (target graph).
