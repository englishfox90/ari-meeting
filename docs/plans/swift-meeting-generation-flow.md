# Swift Meeting Generation Flow

**Status: 2026-07-22.** Plan for the post-recording generation pipeline + saved-meeting summary
actions in the native Swift app. Authored by the principal (Opus) after full discovery of both the
Rust/React reference flow and the current Swift state. Implementation delegated to
`swift-implementer` (Sonnet), reviewed by the principal + `swift-code-reviewer`.

> **Environment caveat (this session):** no Swift/Xcode toolchain is available in the remote Linux
> container, so `swift build`/`swift test`/`xcodebuild` **cannot run here**. Code + tests are
> written to compile-correct-by-construction against verified signatures; **build/test verification
> must run on macOS.** Every dependency signature below was cross-checked against the real source.

## Goal

The Rust app auto-runs a pipeline after every recording: **diarize → auto-suggest template →
generate summary** (summary gated by an `autoSummary` config), and the saved-meeting UI offers
generate/regenerate/change-template/cancel. The Swift app currently **only displays** pre-existing
summaries — recording stop is save-only, and `MeetingDetailView` is read-only save for the
already-wired "Identify speakers" sheet. This plan closes both gaps.

### Product decisions (locked with the owner 2026-07-22)

1. **Speaker ID in the auto-flow: "always, prompt if unknown."** After a recording concludes, always
   attempt speaker identification. Swift diarization deliberately requires a speaker-count hint
   (`DiarizationService.run` throws `hintRequired` on `.automatic` — it never clusters the mixed
   stream blind). So: resolve a hint from the calendar/participant provider; if one exists, run
   diarization automatically; **if none exists, prompt the user for a count** before continuing to
   template + summary. The user may skip the prompt.
2. **Summary trigger: auto, honoring the existing `summaryAutomatic` setting** (default **on** when
   unset). Always **also** expose manual Generate/Regenerate/change-template controls on the saved
   meeting regardless of the setting.
3. **Diarization failure is non-blocking to the summary** (principal decision, diverging from Rust's
   halt-with-retry): a diarization error is recorded honestly in the pipeline phase but the pipeline
   **continues** to template + summary using whatever labels resolved (or none). Rationale: never
   strand a meeting with no summary because clustering hiccuped; the manual "Identify speakers" sheet
   remains available afterward to redo it. (Revisit if retry-UX is wanted later.)

## What already exists (reuse verbatim — do NOT reimplement)

Engine (`AriKit`), all `public`, all unit-tested:

- `SummaryService(db:settings:secrets:cancellation:clientFactory:)` — `.processTranscript(_ SummaryProcessRequest) async throws -> Summary`, `.cancelSummary(_ MeetingID) async -> Bool`. Resolves provider/token-threshold, loads template, generates, persists via repositories, best-effort title-rename/provenance. `SummaryService` is a `Sendable` struct.
- `SummaryProcessRequest(meetingId:text:modelProviderKey:modelName:customPrompt:templateId:summaryLanguage:detectedTranscriptLanguage:customTemplateDirectory:)`.
- `TemplateSelector.suggestTemplate(client: any LLMClient, text:, speakerCount: Int? , calendarContext: String?, customDirectory: URL?) async -> TemplateSuggestion` — never throws, degrades to `standard_meeting`. `TemplateSuggestion { id, name }`. `defaultTemplateID = "standard_meeting"`.
- `TemplateRegistry.listTemplateIDs(customDirectory:) -> [String]`, `.template(id:customDirectory:) throws -> Template` (`Template` has `.name`, `.description`).
- `DiarizationService` (actor) — `.run(meetingId:audioURL:hint:progress:) async throws -> RunResult`, `.confirmSpeaker(_:as:inMeeting:)`, `.assignablePeople()`, `.assignmentSuggestions(forSpeaker:)`. `DiarizationPhase` enum. `SpeakerCountHint { .exact(Int), .upperBound(Int), .automatic }` + `.clampedExact`/`.clampedUpperBound`; ranges `exactRange = 1...20`, `upperBoundRange = 2...12`.
- `SpeakerCountHintProviding.hint(for: MeetingID) async throws -> ResolvedSpeakerHint?` (`{ hint: SpeakerCountHint, origin }`). Concrete: `StoredCalendarHintProvider(database:)`.
- `LabeledTranscript.buildLabeledTranscriptText(db:meetingId:) async throws -> String?` (speaker-labeled "Name: text", `nil` if no speakers resolve) + `.loadTranscriptText(db:meetingId:) async throws -> String` (plain fallback). **This is the transcript assembly — reuse it.**
- `ProviderConfigResolution.resolve(providerKey:modelName:settings:secrets:) async throws -> ProviderConfig`; `ProviderFactory.make(config:session:mlxClientProvider:) throws -> any LLMClient`.
- `SettingsReading.summaryModelConfig() async throws -> SummaryModelConfig?` (`{ providerKey, model }`). App conformer: `StoreBackedSettingsReading(database:)`.
- `AudioAvailabilityResolver.resolve(audioReference:fileExists:) -> AudioAvailability` (`.available(URL)`/`.missing(String)`) — pure, headless. `AriViewModels`.
- `TaskCancellationCoordinator()` (actor).
- Settings: `db.settings.string/bool/int(forKey:)`. Keys `.summaryProvider`, `.summaryModel`, `.summaryLanguage`, `.summaryAutomatic`, `.summaryOllamaEndpoint`, `.summaryCustomOpenAIConfig`.
- App composition root `AppEnvironment` (`Ari/App/AppEnvironment.swift`, `@MainActor @Observable`) already owns `database`, `recordingSession`, `diarizationService`, `speakerCountHintProvider`, `secrets` (`KeychainSecretStore`). Views read it via `@Environment(AppEnvironment.self)`. `MeetingDetailView` already lazily builds `SpeakerIdentificationViewModel` from it — copy that pattern.

## New components

### 0. `SummaryRunner` (AriViewModels, `Sendable` struct) — shared generation core

Centralizes the 5-step generate so both new VMs share ONE copy: assemble text → read summary model
config → resolve `ProviderConfig` → build `any LLMClient` → (auto-suggest template if none given) →
`SummaryService.processTranscript`. No duplicated provider resolution.

```swift
public struct SummaryRunner: Sendable {
    let database: AppDatabase
    let settings: any SettingsReading
    let secrets: any SecretsReading
    let summaryService: SummaryService
    let customTemplateDirectory: URL?         // nil for now (built-ins only)
    // injectable for tests; prod = { try ProviderFactory.make(config: $0) }
    let clientFactory: @Sendable (ProviderConfig) throws -> any LLMClient

    /// Labeled transcript if speakers resolved, else plain. Empty string ⇒ caller treats as
    /// "nothing to summarize" (honest — never fabricates).
    public func transcriptText(for meetingId: MeetingID) async throws -> String

    /// Auto template id for the meeting, never throws (degrades to standard_meeting).
    public func suggestTemplateID(text: String, speakerCount: Int?) async -> String

    /// Full generate. `templateId == nil` ⇒ auto-suggest first. Throws LLMError.notConfigured
    /// when no summary provider/model is configured, or when transcript text is empty.
    public func generate(meetingId: MeetingID, templateId: String?, speakerCount: Int?) async throws -> Summary

    public func cancel(_ meetingId: MeetingID) async -> Bool
}
```

Details:
- `suggestTemplateID`: read `settings.summaryModelConfig()`; if nil → return `TemplateSelector.defaultTemplateID` (can't classify without a model — honest fallback, never throws). Else resolve config, build client, `TemplateSelector.suggestTemplate(...).id`.
- `generate`: `text = try transcriptText(for:)`; guard non-empty else throw `LLMError.notConfigured("This meeting has no transcript to summarize.")`. `guard let cfg = try await settings.summaryModelConfig() else { throw LLMError.notConfigured("No summarization model is configured. Choose one in Settings.") }`. `let tid = templateId ?? await suggestTemplateID(text:, speakerCount:)`. Build `SummaryProcessRequest(meetingId:, text:, modelProviderKey: cfg.providerKey, modelName: cfg.model, customPrompt: "", templateId: tid, summaryLanguage: try? await database.settings.string(forKey: .summaryLanguage), detectedTranscriptLanguage: nil, customTemplateDirectory: customTemplateDirectory)`. Return `try await summaryService.processTranscript(request)`.

### 1. `MeetingSummaryViewModel` (AriViewModels, `@MainActor @Observable`) — deliverable B

Manual summary actions for the saved-meeting view. Mirrors `SpeakerIdentificationViewModel`'s
headless closure-injected shape + honest state spine.

```swift
public enum SummaryGenerationState: Equatable { case idle, generating, failed(String) }
public struct TemplateOption: Identifiable, Sendable, Equatable { public let id: String; public let name: String }

@MainActor @Observable public final class MeetingSummaryViewModel {
    public private(set) var state: SummaryGenerationState = .idle
    public private(set) var templates: [TemplateOption] = []
    /// nil ⇒ "Auto (suggest)". Set from the picker or restored from an existing summary's templateId.
    public var selectedTemplateID: String?

    // designated init takes closures over SummaryRunner (generateOperation, cancelOperation,
    // loadTemplatesOperation); convenience init takes (runner:) + customTemplateDirectory.
    public func loadTemplates()                                   // TemplateRegistry.listTemplateIDs → [TemplateOption]
    public func restoreSelection(from summary: Summary?)          // selectedTemplateID = summary?.templateId
    public func generate(meetingId:, speakerCount: Int?) async -> Summary?   // reentrancy-guarded
    public func cancel(meetingId:) async
}
```

- Reentrancy: refuse when `.generating`.
- `generate`: `state = .generating`; `do { let s = try await generateOp(meetingId, selectedTemplateID, speakerCount); state = .idle; return s } catch is CancellationError/LLMError.cancelled { state = .idle; return nil } catch { state = .failed(String(describing: error)); return nil }`.
- No fabricated content: on failure the view keeps showing the prior summary (unchanged) + the honest error; the VM never invents a summary.

### 2. `MeetingProcessingCoordinator` (AriViewModels, `@MainActor @Observable`) — deliverable A

The post-recording pipeline, **owned by `AppEnvironment`** so it survives navigation
(mount-independent, like `recordingSession`). One active job at a time (mirrors Rust's single
pipeline).

```swift
@MainActor @Observable public final class MeetingProcessingCoordinator {
    public enum Phase: Equatable {
        case idle
        case identifyingSpeakers(DiarizationPhase, Double)
        case needsSpeakerCount                    // paused for user input (app-level sheet)
        case selectingTemplate
        case summarizing
        case completed
        case failed(String)                       // pipeline-fatal only (rare)
    }
    public private(set) var phase: Phase = .idle
    public private(set) var activeMeetingID: MeetingID?
    /// Honest, non-fatal note when diarization was attempted and failed but the pipeline continued
    /// (decision 3). nil otherwise. Surfaced as a soft banner, never blocks.
    public private(set) var diarizationNote: String?

    // Injected closures (headless/testable), mirroring SpeakerIdentificationViewModel:
    //   resolveAudioURL: (MeetingID) async -> URL?         (Meeting.audioReference → AudioAvailabilityResolver)
    //   resolveHint:     (MeetingID) async -> SpeakerCountHint?
    //   runDiarization:  (MeetingID, URL, SpeakerCountHint, @Sendable (DiarizationPhase,Double)->Void) async throws -> Void
    //   isAutoSummaryEnabled: () async -> Bool             (settings .summaryAutomatic ?? true)
    //   generateSummary: (MeetingID, Int?) async throws -> Void   (SummaryRunner.generate, templateId nil = auto)
    //   speakerCount:    (MeetingID) async -> Int?         (distinct stamped speakers, for template signal)

    public func begin(meetingId: MeetingID) async     // idempotent: no-op if already active
    public func provideSpeakerCount(_ hint: SpeakerCountHint) async
    public func skipSpeakerIdentification() async
    public func cancel()
}
```

Pipeline (`begin`):
1. Guard `phase == .idle` (one job). `activeMeetingID = meetingId`.
2. `audioURL = await resolveAudioURL(meetingId)`.
   - `nil` → skip speaker ID entirely (no recording to diarize — Rust "unavailable ≠ failure"); go to step 5.
   - present → `hint = await resolveHint(meetingId)`.
     - hint present → `await runSpeakerID(hint, audioURL)` (step 4).
     - hint nil → `phase = .needsSpeakerCount`; **return** (pause). App presents the count sheet.
3. Resume edges: `provideSpeakerCount(hint)` → `runSpeakerID(hint, storedAudioURL)`; `skipSpeakerIdentification()` → straight to step 5. Both guard `phase == .needsSpeakerCount`.
4. `runSpeakerID`: `phase = .identifyingSpeakers(.preparingModels, 0)`; bridge progress onto the phase (AsyncStream → single @MainActor consumer, exactly like `SpeakerIdentificationViewModel.run`); `do { try await runDiarization(...) } catch { diarizationNote = "Speaker identification didn't complete: \(err). Summary generated without speaker labels." }` — **non-fatal, continue**.
5. `phase = .selectingTemplate`; `count = await speakerCount(meetingId)`. `guard await isAutoSummaryEnabled() else { phase = .completed; return }`. `phase = .summarizing`; `do { try await generateSummary(meetingId, count) } catch is CancellationError { phase = .idle; return } catch { phase = .failed(String(describing: error)); return }`. `phase = .completed`.
- `cancel()`: cancels the running task; `phase = .idle`, `activeMeetingID = nil`. (Cancelling summary also calls `SummaryRunner.cancel` via the injected op if in `.summarizing` — wire a cancel closure.)
- Progress bridging + reentrancy guard identical to `SpeakerIdentificationViewModel` (copy the pattern; keep `progressTask` test hook).

## App wiring (`AppEnvironment.bootstrap()`)

Add, after `speakerCountHintProvider` is set (all inside the `status = .ready` success path):

```swift
let settingsReader = StoreBackedSettingsReading(database: db)
let summaryService = SummaryService(db: db, settings: settingsReader, secrets: secrets,
                                    cancellation: TaskCancellationCoordinator())
self.summaryService = summaryService
let runner = SummaryRunner(database: db, settings: settingsReader, secrets: secrets,
                           summaryService: summaryService, customTemplateDirectory: nil,
                           clientFactory: { try ProviderFactory.make(config: $0) })
self.summaryRunner = runner

let coordinator = MeetingProcessingCoordinator(
    resolveAudioURL: { [weak db] mid in /* find meeting → AudioAvailabilityResolver.resolve(...fileExists: FileManager) → .available(url) */ },
    resolveHint: { mid in try? await hintProvider.hint(for: mid).map(\.hint) },   // hintProvider = the same StoredCalendarHintProvider
    runDiarization: { mid, url, hint, progress in _ = try await diar.run(meetingId: mid, audioURL: url, hint: hint, progress: progress) },
    isAutoSummaryEnabled: { (try? await db.settings.bool(forKey: .summaryAutomatic)) ?? nil ?? true },
    generateSummary: { mid, count in _ = try await runner.generate(meetingId: mid, templateId: nil, speakerCount: count) },
    speakerCount: { mid in /* distinct stamped speakerIds count, or nil */ },
    cancelSummary: { mid in _ = await runner.cancel(mid) }
)
self.processingCoordinator = coordinator
```

New `AppEnvironment` stored props: `summaryService: SummaryService?`, `summaryRunner: SummaryRunner?`,
`processingCoordinator: MeetingProcessingCoordinator?`. All `private(set)`, `nil` until ready.

## UI integration (`Ari/UI`)

1. **App-level speaker-count prompt** (mount-independent). In `RootSplitView` (or `AppShell`), add a
   `.sheet` bound to `processingCoordinator.phase == .needsSpeakerCount`. A new compact
   `SpeakerCountPromptSheet` (Marginalia): exact-count field + "Not sure / at most" field (reuse the
   H2 two-mode idea from `IdentifySpeakersSheet`), **Skip** → `coordinator.skipSpeakerIdentification()`,
   **Identify** → `coordinator.provideSpeakerCount(.clampedExact/​.clampedUpperBound)`. Honest, no
   defaults invented; dismiss = Skip.
2. **`RecordingView.savedContent`**: on entering `.saved(meetingId)` (a `.task`/`.onChange` in
   `RecordingView`), call the injected `onRecordingSaved(meetingId)` → `coordinator.begin`. Render a
   compact live pipeline status from `coordinator.phase` (honest phase labels + progress) above the
   existing "New recording"/"Open meeting" buttons. "Open meeting" stays available throughout.
3. **`MeetingDetailView`** (deliverable B + banner):
   - Add manual summary actions in the summary column header / empty state: **Generate summary**
     (when no summary), **Regenerate** + **Change template** (when a summary exists), **Cancel** while
     generating. Lazily build `MeetingSummaryViewModel` from `environment.summaryRunner` (copy the
     `speakerIdentificationViewModel` lazy-build pattern). On success → `await viewModel.load(meetingId)`
     (refresh, same as `onSpeakersChanged`). Template picker = `Menu`/`Picker` over
     `summaryVM.templates` with an "Auto (suggest)" entry (nil). `speakerCount` arg =
     `viewModel.speakerNames.count` (real signal) or nil.
   - Add a lightweight `MeetingProcessingBanner` shown only when
     `environment.processingCoordinator?.activeMeetingID == meetingId`, reflecting `phase`
     (diarizing/selecting/summarizing) + `diarizationNote`. When the coordinator reaches `.completed`
     for this meeting, `await viewModel.load(meetingId)` to pull the new summary. No-Fake-State: the
     banner shows only real phases; it never shows a fake progress bar over invented steps.
   - Manual actions are **disabled while the coordinator is actively processing this meeting**
     (prevents concurrent summaries — mirrors Rust's `isBackgroundProcessing` gate).

## Invariants to preserve (checked in review)

- **No-Fake-State**: every phase/state is real; empty/failed states are honest; no fabricated
  summary, template name, speaker name, or progress. Failure keeps the prior summary visible.
- **Repositories-only / single DB owner**: all persistence stays inside `SummaryService`/
  `DiarizationService` (already repository-backed). New code never opens SQLite or writes rows
  directly — it only calls those services + reads via `AppDatabase` repositories.
- **Consent-before-record untouched**: this flow runs strictly post-recording; it opens no capture
  path. The coordinator's diarization refuses to run while recording is active is inherited from the
  service layer; the coordinator only ever runs after `.saved`.
- **Confirm-before-enroll**: auto-diarization only auto-stamps AutoConfirm-tier voiceprints (already
  enforced in `DiarizationService`); provisional speakers still require the manual sheet to confirm.
- **Swift 6 strict concurrency**: VMs `@MainActor`; services `Sendable`/actors; progress via
  AsyncStream + one `@MainActor` consumer. No `@unchecked Sendable`/`nonisolated(unsafe)`.
- **Loopback-only Ollama**: inherited from `ProviderFactory.make` gate — unchanged.

## Acceptance tests (Swift Testing; author with the code)

`SummaryRunnerTests`:
- assembles labeled text when speakers resolve, plain otherwise; empty transcript → throws notConfigured.
- no summaryModelConfig → `generate` throws notConfigured; `suggestTemplateID` returns default.
- `templateId: nil` path calls the classifier; explicit id skips it (assert via a stub client/selector).

`MeetingSummaryViewModelTests`:
- generate success → `.idle`, returns Summary; failure → `.failed(msg)` and returns nil (prior summary untouched at the view layer — VM has no summary state to clobber).
- cancellation → `.idle`, returns nil (not `.failed`).
- reentrancy: second `generate` while `.generating` is refused.
- `loadTemplates` yields the built-ins; `restoreSelection` mirrors `summary.templateId`.

`MeetingProcessingCoordinatorTests`:
- hint present → runs diarization then summarizes → `.completed`; diarization progress reaches `phase`.
- hint nil → `.needsSpeakerCount`; `provideSpeakerCount` resumes to `.completed`; `skipSpeakerIdentification` resumes skipping diarization.
- no audio → skips speaker ID, still summarizes → `.completed`.
- diarization throws → `diarizationNote` set, pipeline continues to `.completed` (non-fatal, decision 3).
- `summaryAutomatic == false` → stops at `.completed` after speaker step with no summary generated.
- summary throws → `.failed`; summary cancelled → `.idle`.
- reentrancy: `begin` while active is a no-op.

## Build order

- **Track 1** (foundation + deliverable B): `SummaryRunner`, `MeetingSummaryViewModel` (+tests),
  `AppEnvironment` wiring of `summaryService`/`summaryRunner`, `MeetingDetailView` manual actions +
  template picker. Reviewed + (on macOS) green before Track 2.
- **Track 2** (deliverable A): `MeetingProcessingCoordinator` (+tests), `AppEnvironment` coordinator
  wiring, `SpeakerCountPromptSheet` + app-level presentation, `RecordingView` kickoff + status,
  `MeetingDetailView` processing banner. Depends on Track 1's `SummaryRunner` + wiring.
</content>
</invoke>
