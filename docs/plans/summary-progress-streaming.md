# Plan: Summary phase progress + final-report token streaming

## 1. Goal & seam

Make on-device (MLX Qwen3.5-4B) summary generation legible: surface the *real* map-reduce pipeline stage as an honest phase label, and stream the final-report pass token-by-token so the report visibly fills in instead of appearing all at once after minutes of opaque spinner.

**Seam & phase.** Attaches to the summary-prompt-assembly seam (`SummaryGenerator`) and the Phase-2 native-shell UI track (`docs/plans/swift-meeting-generation-flow.md` Tracks 1 & 2). Lands entirely on the Swift/target side of the cut — the frozen Rust app rendered summaries as a buffered blob and never streamed generation to the UI (only Ask/recall streamed there). So this is **net-new Swift display capability, not a re-implementation of a frozen Rust feature** — clears plan principle 8. The engine's generation logic is unchanged in substance; only its final visible pass switches from buffered `generate()` to the already-shipped `stream()`, plus additive progress emission.

## 2. Module & surface

Engine changes in `AriKit` (`Engine/Summary`); VM changes in `AriViewModels`; view changes in the `Ari` app target.

### 2a. New value type — `SummaryProgress` (AriKit, `Engine/Summary/SummaryProgress.swift`)

```swift
public enum SummaryProgress: Sendable, Equatable {
    case summarizingChunk(index: Int, total: Int)   // 1-based; map-reduce chunk passes
    case combining                                   // only when chunkSummaries.count > 1
    case writingFinalReport                          // final-report pass begins
    case finalReportDelta(String)                    // one streamed token/chunk of the visible report
    case normalizingEnglish                          // LanguageResolution.normalizeEnglish pass
    case translating(language: String)              // LanguageResolution.translate pass
}
```

A single ordered channel carries both coarse phase transitions and fine-grained final-report deltas. Deltas (not accumulated snapshots) keep each event small and Sendable-cheap; the consumer accumulates. `Equatable` makes the ordered-sequence test trivial.

### 2b. `SummaryGenerator.generateMeetingSummary` — additive optional emitter

Add one trailing param, mirroring `DiarizationService.run` (`progress: (@Sendable (…) -> Void)? = nil`):

```swift
public static func generateMeetingSummary(
    client: any LLMClient,
    text: String,
    customPrompt: String = "",
    templateID: String,
    template: Template,
    tokenThreshold: Int = 4000,
    summaryLanguage: String? = nil,
    detectedTranscriptLanguage: String? = nil,
    progress: (@Sendable (SummaryProgress) -> Void)? = nil   // NEW
) async throws -> SummaryGenerationResult
```

Keep the one method with an optional emitter — do NOT add a separate streaming variant. `progress: nil` reproduces today's behavior byte-for-byte.

Emission points inside the existing body:
- Chunk loop (before each `client.generate`): `progress?(.summarizingChunk(index: i + 1, total: chunks.count))`.
- Before the combine pass (inside the `chunkSummaries.count > 1` branch): `progress?(.combining)`.
- Final-report pass — **the streamed pass**: emit `.writingFinalReport`, then replace the buffered `client.generate(...)` with a stream-consuming loop:

```swift
progress?(.writingFinalReport)
var rawMarkdown = ""
do {
    for try await delta in client.stream(LLMRequest(system: finalSystemPrompt, user: finalUserPrompt)) {
        try Task.checkCancellation()
        rawMarkdown += delta
        progress?(.finalReportDelta(delta))
    }
} catch is CancellationError { throw LLMError.cancelled }
catch let LLMError.cancelled { throw LLMError.cancelled }
```

- Normalize/translate passes: emit `.normalizingEnglish` / `.translating(language:)` immediately before their existing `client.generate` calls. These stay **buffered** (out of scope; behavior identical) — only a phase label is added.

**Byte-for-byte-identical result guarantee.** Chunk/combine/normalize/translate passes untouched. The final pass's `rawMarkdown` is the concatenation of the same completion the model would return buffered (MLX `stream`/`generate` drive the same `ChatSession` with the same params). `Chunking.cleanLLMMarkdownOutput` + `SummaryCitations.applyCitations` run on that accumulated string exactly as before. `SummaryGenerationResult` is identical whether `progress` is nil or set — streaming is a pure display side-channel.

Single-*chunk* map-reduce sub-case emits no `.combining` (matches the pipeline). Tests assert this.

### 2c. Single-pass / cloud path also streams its one visible pass

The non-map-reduce branch hits the same final-report pass, so switching that pass to `client.stream` means short transcripts and cloud providers stream their single visible pass for free. Providers without true token streaming (ClaudeCLI, FoundationModels) fall back to the `LLMClient.stream` protocol-extension single-yield — one `.finalReportDelta` with the full report. No regression.

### 2d. `SummaryService.processTranscript` — thread the emitter

Add `progress: (@Sendable (SummaryProgress) -> Void)? = nil` to `processTranscript` + `runGeneration`, passed into `generateMeetingSummary`. No `SummaryProcessRequest` change (progress is a live callback, not persisted). Cancellation registry, persistence, and no-partial-write guarantee untouched — the emitter fires only inside the already-cancellable `generationTask`.

### 2e. `SummaryRunner.generate` — thread the emitter

Add `progress: (@Sendable (SummaryProgress) -> Void)? = nil`, forwarded to `summaryService.processTranscript`. `SummaryRunner` is the single shared core for both call sites (manual VM + auto coordinator), so both opt in through one path.

### 2f. `MeetingSummaryViewModel` (manual path) — observable progress state

```swift
public private(set) var phaseLabel: String?     // nil unless generating
public private(set) var streamedReport: String  // "" until final pass
```

Extend `GenerateOperation` with a trailing `progress` param; set up the engine→MainActor bridge (§3); reset both on completion/cancel/failure. Reentrancy guard + state mapping unchanged. Labels derived on MainActor from `SummaryProgress` (engine stays UI-string-free): `.summarizingChunk(i,n)` → "Summarizing part i of n"; `.combining` → "Combining"; `.writingFinalReport` → "Writing final report"; `.normalizingEnglish` → "Normalizing to English"; `.translating(l)` → "Translating to l". `.finalReportDelta` appends to `streamedReport`.

### 2g. `MeetingProcessingCoordinator` (auto path) — reuse its existing bridge

```swift
public private(set) var summaryPhaseLabel: String?
public private(set) var streamedReport: String
```

Extend `GenerateSummaryOperation` with a trailing `@Sendable` progress param. In `proceedToTemplateAndSummary`, bridge exactly like `runSpeakerID` bridges diarization progress: `AsyncStream.makeStream()`, one `@MainActor` consumer task, emitter yields to the continuation. Reset on terminal state; `cancel()` clears the two new properties. `AppEnvironment.bootstrap` wires the coordinator's `generateSummary` closure to `runner.generate(…, progress:)`.

### 2h. `Ari` app target — rendering

- New `SummaryStreamingView(phaseLabel:partialMarkdown:scheme:)`: phase label (`.marginaliaTextStyle(.caption)`) above `MarginaliaMarkdownView(markdown:onSeek:nil)` when partial is non-empty. Reused by both paths.
- `MeetingDetailView.summaryBody`: while manual VM is `.generating`, show `SummaryStreamingView` in place of "No summary yet". On completion the existing reload replaces it with the persisted cited body.
- `processingBanner`: for `.summarizing`, use `coordinator.summaryPhaseLabel ?? "Generating summary…"`; render `coordinator.streamedReport` via the same view when active.
- Toolbar Cancel unchanged.

**No-Fake-State:** intermediate chunk/combine/normalize text is NEVER shown as content — only the phase label. Only the final-report pass streams content, honestly labeled. The streamed partial is display-only, pre-citation; the authoritative persisted body replaces it on reload.

## 3. Concurrency model

The emitter fires off the main actor, from inside the engine's background generation `Task`. `SummaryProgress` is `Sendable`.

**Decision: engine takes a `@Sendable (SummaryProgress) -> Void` emitter; the VM/coordinator bridges it onto an `AsyncStream<SummaryProgress>` consumed by a single `@MainActor` task.** This is the documented, tested precedent (`MeetingProcessingCoordinator`): a raw closure hopping to MainActor per call risks reordered/lost updates because each hop schedules independently. One consumer draining one stream guarantees in-order, one-at-a-time delivery — deterministic, no races. Engine stays isolation-agnostic; only the app layer touches `@MainActor`.

- Engine work stays entirely off the main actor (MLX inference must never block MainActor).
- Bridge: `let (stream, continuation) = AsyncStream<SummaryProgress>.makeStream()`; emitter = `{ continuation.yield($0) }`; `let consumer = Task { @MainActor in for await p in stream { apply(p) } }`; `continuation.finish()` after generate returns; `await consumer.value` before returning so all updates land before the terminal state.
- No `@unchecked Sendable` / `nonisolated(unsafe)`.

## 4. Persistence

**No schema change.** The persisted `Summary` (`bodyMarkdown` + provider/model/templateId provenance) is written from the identical `SummaryGenerationResult` as today. Single-DB-owner reasserted: writes stay through `AppDatabase` repositories; the emitter never touches the Store; no partial/streamed text is ever persisted.

## 5. Acceptance tests (Swift Testing — written first)

Engine tests drive off the existing `StubLLMClient` (`cannedDeltas` streams). Net-new Swift capability — no Rust dual-run suite.

1. **Phase order (N chunks):** exact prefix `[.summarizingChunk(1,N)…(N,N), .combining, .writingFinalReport]` then ≥1 `.finalReportDelta`.
2. **Single-chunk omits `.combining`.**
3. **Final tokens stream:** concatenation of `.finalReportDelta` == stub canned final deltas.
4. **Persisted-body identity:** same input twice (nil vs emitter) → byte-identical `finalMarkdown`/`englishMarkdown`.
5. **Citations vs ORIGINAL transcript** preserved.
6. **One-bad-chunk-skips:** chunk 2 of 3 throws → completes, `chunkCount == 2`.
7. **Cancellation mid-stream:** `LLMError.cancelled`, no summary row, stream/consumer torn down.
8. **Single-pass / cloud path:** only `.writingFinalReport` + `.finalReportDelta`; single-yield fallback body matches buffered baseline.
9. **Translate/normalize labeled, behavior unchanged.**
10. **VM-level:** `phaseLabel` ordered, `streamedReport` grows monotonically, both reset on success, reentrancy guard holds.
11. **Coordinator-level:** auto-path `summaryPhaseLabel`/`streamedReport` populated then cleared; diarization→summary ordering intact.

## 6. Invariants preserved

- Never-invents-citations / citations against original transcript (test 5).
- No-Fake-State: labels map to real stages; scratch text never shown; streamed partial honestly labeled + non-authoritative (tests 1,2,8).
- Cancellation: `Task.checkCancellation()` between passes + per-delta; `cancelSummary`/`TaskCancellationCoordinator` unchanged; MLX stream cancels per-chunk (test 7).
- One-bad-chunk-skips (test 6).
- Language normalize/translate behavior unchanged (test 9).
- Persisted-result identity guaranteed (test 4).
- On-device only — no provider/routing change.
- Single-DB-owner — writes stay in `SummaryService.persist`.

## 7. Risks & sequencing

1. Add `SummaryProgress` + engine emission + final-pass `stream()` switch (`progress: nil` default). Land tests 1–9. Whole engine risk surface; test 4 catches regressions.
2. Thread the optional emitter through `SummaryService` + `SummaryRunner` (default nil — no caller changes yet).
3. `MeetingSummaryViewModel` observable progress + bridge; test 10.
4. `MeetingProcessingCoordinator` observable progress + bridge; test 11; wire `AppEnvironment.bootstrap`.
5. `Ari` app rendering; verify visually via XcodeBuildMCP on a real ≥20-min meeting.

**Risk notes.** Partial markdown mid-stream may render transiently malformed (open `**`, half a table row) in `MarginaliaMarkdownView` — acceptable, self-corrects, replaced by clean persisted body on completion. Debounce is a later refinement. No spike gate outstanding — S1/MLX is GO; `MLXClient.stream` already implemented/verified against `mlx-swift-lm` 3.31.4.

**Migration/rollout.** Purely additive/backward-compatible: every new param defaults to `nil`, untouched callers keep today's exact behavior — no feature flag.

## Open decisions for the human

1. **English-streams-then-swaps-to-translation** in non-English meetings: streamed final pass is the English report; persisted/visible body is the translated text (subsequent buffered pass). User sees English stream in, then swap. Honest but a minor jag. Accept (label makes it honest), or suppress streaming display when a translate pass is pending? Recommendation: accept.
2. **Debounce of partial-markdown re-render** — ship raw per-token first, or add a coalescing interval up front? Recommendation: ship raw; measure.

## Relevant files
- `AriKit/Sources/AriKit/Engine/Summary/SummaryGenerator.swift`
- `AriKit/Sources/AriKit/Engine/Summary/SummaryService.swift`
- `AriKit/Sources/AriViewModels/SummaryRunner.swift`
- `AriKit/Sources/AriViewModels/MeetingSummaryViewModel.swift`
- `AriKit/Sources/AriViewModels/MeetingProcessingCoordinator.swift`
- `AriKit/Sources/AriKitEngineMLX/MLXClient.swift`
- `AriKit/Sources/AriKit/Engine/Providers/LLMClient.swift`
- `AriKit/Sources/AriKit/Engine/Providers/StubLLMClient.swift`
- `AriKit/Sources/AriKit/Engine/Diarization/DiarizationService.swift` (progress-callback precedent)
- `Ari/UI/MeetingDetails/MeetingDetailView.swift`

---

## Note on prerequisite (added by main loop, 2026-07-22)

Before implementing this, resolve the **Debug-vs-Release speed question**: the observed multi-minute wait was measured on a Debug (`-Onone`) build, where the MLX Swift generation loop/sampler/tokenizer are unoptimized; the Rust "seconds" comparison was a release-optimized `llama-helper`. The Swift `MLXClient.defaultMaxTokens` is also 1200 vs the Rust helper's 512 default. Re-time a full-length summary on a **Release** build first. If Release is fast, this feature is a legibility nicety rather than a mitigation for an unavoidable wait — still worth building, but it reframes the urgency and may pair with lowering `defaultMaxTokens`.
