# AriKit `Engine/STT/` — SpeechAnalyzer / SpeechTranscriber port (plan)

> **Status (2026-07-20): ✅ COMPLETE — shipped, gate PASSED.** Slices A/B/C/D/E landed on `main`
> (`db7cac0`→`9e3e8c7`, plan `f8bf35b`) via the Sonnet-implement / Haiku-verify / Sonnet-review
> workflow (zero blockers). Final gate (main loop): `swift build` + full `swift test` green
> (**427 tests / 62 suites, 0 warnings, Swift 6 strict**); scope pristine (only `Engine/STT/**` +
> tests; `Package.swift` untouched, no committed audio). **Lane-3 S2 accuracy gate PASSED** — the
> product `SpeechTranscriberProvider` scored **mean core WER 0.2345 ≤ Parakeet baseline 0.2814**
> over the 5 held-out meetings (reproduces the S2 spike ~0.234; beats Parakeet on 4/5, the `metro2`
> loss being the anticipated documented exception), **100% word-timestamp coverage** and punctuation
> on every meeting, and the longest real file (~45 min) transcribed single-pass with **no
> truncation** (the rig's "~78/80 min" labels are the known 2× `audio_end_time` DB bug, which the
> harness's real `AVAudioFile` durations of ~39–40 min independently confirmed). WhisperKit remains
> deferred; the **live-stream path is designed + shape/cancellation-tested only — it awaits its real
> mic feed from Phase 3.2**.
>
> **Original gate rulings (still authoritative for the record):** See **§11 Gate decisions** —
> authoritative where it differs from §9. Headline overrides: the accuracy-eval harness was **NOT**
> added to `AriKit/Package.swift` (built main-loop-side at the final gate); implementation slices
> touched **only** `AriKit/Sources/AriKit/Engine/STT/**` + `AriKit/Tests/**`, zero `Package.swift`,
> zero new deps; Lane-2 commits **no audio**.

## 0. Status & scope guard

Phase **3.3** ("STT") of `plans/swift-migration-plan.md:174`: *"Whisper/Parakeet → SpeechAnalyzer (turnkey) and/or WhisperKit per the S2 outcome. Already proven once in `apple-helper`. Includes the model-download manager (SpeechAnalyzer assets are OS-managed — a chunk of this module dissolves; WhisperKit/MLX models still need managed downloads). Live-transcription port reference: Apple's `RecognizingSpeechInLiveAudio` sample … Wire the mic input as an `AsyncSequence<AnalyzerInput>`."* Subsystem-map rows: `whisper.cpp / Parakeet → SpeechAnalyzer / WhisperKit … Med (quality — S2 genuinely open) … 3.3` (`swift-migration-plan.md:242`), `model-download manager → Partly dissolves … 3.3` (`:243`), `apple-helper (STT/FM probe) → Absorbed in-process … 3.3` (`:255`).

**Honest framing — this IS a framework swap of a frozen feature, not a logic port and not net-new capability.** Principle 8 (`swift-migration-plan.md:45`) forbids *new* capability on the Rust side and mandates ports land on the target Swift side. Ari's STT (whisper.cpp + Parakeet-ONNX behind `TranscriptionProvider`, `frontend/src-tauri/src/audio/transcription/provider.rs:50`) shipped on Rust and is frozen. But unlike the recall/summary ports (which reproduce Rust *logic* line-for-line), the STT engines **dissolve into a system framework** — the migration plan's own words are *"replaced by SpeechAnalyzer, not ported"* (`swift-migration-plan.md:8`). There is no whisper.cpp/ONNX inference loop to re-implement in Swift: `SpeechAnalyzer`/`SpeechTranscriber` *is* the replacement engine. So Phase 3.3 is **(a)** a thin capture-agnostic Swift wrapper around a system framework, held to a **quality gate** (the S2 rig), plus **(b)** deterministic Swift tests for the plumbing (segment→`Transcript` mapping, timestamp extraction, the asset manager, protocol conformance). This is sanctioned porting work under principles 2/6, not a forbidden second Rust track. S2 is **GO-with-caveats → adopt `SpeechTranscriber`** (`swift-migration-plan.md:94`); this stint reproduces that spike result in the product path.

**WIP-limit / phase check (principle 8).** This is one migration phase (3.3). It does not open a second product feature. Phase 3.4 (summary/providers) and Recall Slices 1–8 have already landed (`swift-migration-plan.md:11,16`); STT is *independent of both* — it produces `Transcript` rows that everything downstream already consumes. The one cross-stream seam is a small **additive Store hand-off** (an optional batch transcript-write, §4) analogous to how the engine-providers plan flagged `meetingParticipant` (`arikit-engine-providers.md §4`). STT does **not** block on capture (3.2): the file-URL path is fully verifiable now against existing recordings; the live-stream interface is *designed* here and *fed* by 3.2 later.

**Scope guard (as gated — see §11).** Implementation touches only `AriKit/Sources/AriKit/Engine/STT/**` (a new subtree) and `AriKit/Tests/AriKitTests/Engine/STT/**`, plus this doc. **`AriKit/Package.swift` is NOT edited** (the eval harness moves main-loop-side, §11). Any Store write is an explicit, additive hand-off called out in §4 and deferred to Phase 3.2. **No Rust file, no `Cargo.toml`, no `frontend/**` is edited.** Where Swift and Rust disagree, the plan documents the delta; it never edits Rust to reconcile. `apple-helper/` and `spikes/speechanalyzer-s2/` are **read-only references** whose logic is absorbed — they are not modified.

**Cross-references:** `plans/swift-migration-plan.md` (Phase 3 step 3; principles 2/6/7/8; the S2 spike result `:94`; subsystem-map `:242,:243,:255`), `docs/plans/arikit-engine-providers.md` (Phase 3.4 — the gate/slice/test-lane pattern this doc mirrors; the injectable-seam headless-test pattern; the "separate target for a heavy dep" pattern from §8), `docs/plans/arikit-recall.md` (§3 concurrency posture; §6 dual-run test discipline; the `RecallEmbedder`/in-process-`NLEmbedding` "the sidecar hop vanishes" precedent), `docs/plans/arikit-store.md` (the `TranscriptRepository`/`AppDatabase` single-owner pattern this hands off to). Reference implementations (read-only): `spikes/speechanalyzer-s2/Sources/speechanalyzer-s2/Entry.swift` (the proven whole-file driver), `apple-helper/Sources/apple-helper/Transcribe.swift` + `EnsureAssets.swift` + `Probe.swift` (the verified in-process SpeechAnalyzer usage + AssetInventory install + availability probe), `tools/stt-eval/` (the acceptance rig).

## 1. Goal & seam

Replace the frozen Rust `TranscriptionProvider` trait + whisper.cpp/Parakeet-ONNX engines (`frontend/src-tauri/src/audio/transcription/provider.rs`, `whisper_engine/`, `parakeet_engine/`) with a **capture-agnostic Swift STT layer** under `AriKit/Sources/AriKit/Engine/STT/`, built on Apple's on-device `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26). Today `Engine/` holds only `Providers/` + `Summary/` (`Engine/Engine.swift:22`); this adds the `STT/` subtree.

It attaches to seam #1 (**audio pipeline**, `architecture.md`) — but *only on the STT side of the cut*, downstream of capture. In the frozen Rust app, decoded PCM windows (VAD-gated, 16 kHz mono f32) flow from `audio/pipeline.rs` into the transcription worker pool (`audio/transcription/worker.rs`), each window handed to `TranscriptionProvider::transcribe(audio, language)` (`provider.rs:59`) and the resulting text stamped with `audio_start_time`/`audio_end_time` computed from the VAD window boundaries (`worker.rs:202-225`). The **capture-agnostic** boundary this port draws: STT consumes **either** an audio *file URL* (the verified recorded-file path — existing recordings + the S2 rig) **or** a live `AsyncSequence<AnalyzerInput>` (the mic path Phase-3.2 capture will feed). Everything lands on the **target (Swift) side** of the seam (principle 8).

**A structural difference from the Rust incumbent, stated up front:** the Rust trait is *segment-in-text-out* — the caller (`worker.rs`) already did VAD segmentation and owned the timestamp math, because whisper/parakeet have **no internal segmentation and no word-level timing** (Parakeet's DB rows carry only VAD-window `audio_start_time`/`audio_end_time`, `stt-eval/lib/db.mjs:31-42`; the S2 rig calls out "Parakeet has segment-level timestamps only, no word-level", `score.py:20`). `SpeechTranscriber` **segments internally and emits per-word `audioTimeRange` + `transcriptionConfidence`** (`Entry.swift:167,199-214`; S2 measured 100% word-timestamp coverage, `swift-migration-plan.md:94`). So the Swift protocol is naturally **segment-*emitting*** (produces `[TranscriptionSegment]` with real timings), not text-in-text-out. This is a capability *gain* the port should surface, not flatten — it's what makes richer `@ref(MM:SS)` play-badges possible.

## 2. Module & surface

### 2.1 File layout under `Engine/STT/`

```
Engine/STT/
├─ STT.swift                       (module doc + `enum STT` namespace)   ── SLICE A
├─ TranscriptionProvider.swift     protocol + TranscriptionResult/Segment/WordTiming/Error  ── SLICE A (pure)
├─ StubTranscriptionProvider.swift #if DEBUG deterministic test double (canned segments)     ── SLICE A (pure)
├─ STTLocale.swift                 locale resolution (auto/auto-translate → Locale.current)  ── SLICE A (pure-ish)
├─ CMTimeMapping.swift             CMTime→sec, per-run word/confidence extraction helpers     ── SLICE A/C
├─ SpeechAssetManager.swift        AssetInventory availability/install/installed-locale       ── SLICE B (absorbs EnsureAssets)
├─ SpeechTranscriberProvider.swift the SpeechAnalyzer/SpeechTranscriber conformer (file+live) ── SLICE C (file) / SLICE E (live)
└─ TranscriptMapping.swift         TranscriptionSegment → Models.Transcript (pure)            ── SLICE D
```

`STT` is capture-agnostic and **stateless** (like the provider layer, `arikit-engine-providers.md §3`): it produces `[TranscriptionSegment]`, never writes the DB. Persisting those as `Transcript` rows is the capture/orchestration layer's job (Phase 3.2), through `TranscriptRepository` (§4). `SpeechAnalyzer`/`SpeechTranscriber` is a **system framework** (`import Speech`), so unlike MLX (`arikit-engine-providers.md §8`) there is **no SPM dependency and no separate target** — STT lives in the core `AriKit` target and stays headlessly `swift test`-buildable. `AriKit/Package.swift` already floors at macOS 26 / iOS 26 (`Package.swift:50-53`), so `Speech`/`AVFoundation` import with no `@available` guards (same as `apple-helper` — `Transcribe.swift:39-49`).

### 2.2 Public Swift surface — Slice A (the protocol; pure, portable today)

The Swift mirror of the Rust `TranscriptionProvider` trait (`provider.rs:50`), reshaped to be segment-emitting and capture-agnostic, and **WhisperKit-ready without pulling the dep** (§9(1)).

```swift
/// One speech-to-text backend. The Swift mirror of the Rust `TranscriptionProvider` trait
/// (provider.rs:50), reshaped: SpeechTranscriber segments internally and emits per-word timing +
/// confidence, so this protocol is segment-EMITTING, not the Rust text-in/text-out shape.
/// `Sendable` so it crosses actor boundaries freely. All work is off the main actor by construction.
public protocol TranscriptionProvider: Sendable {
    /// A stable identifier for logging/provenance (← `provider_name()`, provider.rs:72),
    /// e.g. "speechanalyzer" / "whisperkit". Persisted as `Meeting.transcriptionProvider`.
    var providerName: String { get }

    /// Is a usable model/engine available on THIS device right now? (← `is_model_loaded()`,
    /// provider.rs:66; for SpeechTranscriber this is `SpeechTranscriber.isAvailable` + installed
    /// assets — Probe.swift.) No fabrication: false when it genuinely can't run.
    func isAvailable() async -> Bool

    /// The model/locale currently in use, if resolvable (← `get_current_model()`, provider.rs:69).
    func currentModel() async -> String?

    /// RECORDED-FILE path (VERIFIED this stint). Transcribe a whole audio file to finalized
    /// segments. Mirrors the S2 spike's `analyzeSequence(from: AVAudioFile)` whole-file driver
    /// (Entry.swift:244) — no manual chunking. `language` is the optional hint (← the Rust
    /// `language: Option<String>` arg, provider.rs:61), incl. the "auto"/"auto-translate"/""
    /// sentinels (§2.4). Throws `TranscriptionError` honestly on any failure (No-Fake-State).
    func transcribe(fileURL: URL, language: String?) async throws -> TranscriptionResult

    /// LIVE path (DESIGNED here, NOT verified this stint — Phase 3.2 feeds it). Consume a caller-
    /// owned async sequence of already-decoded PCM buffers and yield finalized segments as they
    /// finalize. Mirrors apple-helper's `analyzer.start(inputSequence:)` + `AnalyzerInput(buffer:)`
    /// (Transcribe.swift:165-170) generalized to a stream. The element is Apple's `AnalyzerInput`
    /// so capture never has to know STT internals; STT never touches the audio callback thread.
    func transcribe(
        liveInputs: some AsyncSequence<AnalyzerInput, Never> & Sendable,
        language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

/// The full result of a recorded-file transcription (← `TranscriptResult`, provider.rs:42, but
/// carrying real segments rather than one flat string). `fullText` is the segments joined,
/// matching the S2 rig's top-level `text` field (Entry.swift:253).
public struct TranscriptionResult: Sendable, Equatable {
    public var segments: [TranscriptionSegment]
    public var fullText: String            // segments' text joined with a single space
    public var audioDurationSec: Double?    // AVAudioFile length / sampleRate (Entry.swift:140)
    public var wordTimestampCount: Int      // runs carrying `.audioTimeRange` (Entry.swift:210)
}

/// One finalized transcript segment (an `isFinal` `SpeechTranscriber.Result`, Entry.swift:200).
public struct TranscriptionSegment: Sendable, Equatable {
    public var text: String
    public var startSec: Double             // CMTimeGetSeconds(result.range.start)
    public var endSec: Double               // CMTimeGetSeconds(result.range.end)
    public var confidence: Double?          // mean per-run confidence, nil if SDK gives none
    public var words: [WordTiming]          // per-word timing (Parakeet had none — a gain)
}

/// Per-word timing extracted from an AttributedString run's `.audioTimeRange` (Entry.swift:209).
public struct WordTiming: Sendable, Equatable {
    public var text: String
    public var startSec: Double
    public var endSec: Double
    public var confidence: Double?
}

/// ← `TranscriptionError` (provider.rs:14), given matchable cases + three honest No-Fake-State cases.
public enum TranscriptionError: Error, Sendable, Equatable {
    case modelNotLoaded                             // ← ModelNotLoaded (provider.rs:15)
    case audioTooShort(samples: Int, minimum: Int)  // ← AudioTooShort (provider.rs:16)
    case engineFailed(String)                       // ← EngineFailed (provider.rs:17)
    case unsupportedLanguage(String)                // ← UnsupportedLanguage (provider.rs:18)
    case providerUnavailable(String)                // NEW: engine/assets not on this device
    case assetsNotInstalled(locale: String)         // NEW: locale resolvable but model not downloaded
    case audioDecodeFailed(String)                  // NEW: AVAudioFile could not open the file URL
}
```

**Notes on the mapping to Rust:**
- `is_model_loaded()`/`get_current_model()`/`provider_name()` port 1:1 as `isAvailable()`/`currentModel()`/`providerName`. `provider_name()` was `&'static str` (`provider.rs:72`); Swift keeps it a plain `String` property.
- The Rust `transcribe(Vec<f32>, Option<String>)` per-VAD-window entrypoint **does not** port directly — its per-window model is subsumed by SpeechTranscriber's internal segmentation on the file path, and by the caller-owned `AnalyzerInput` stream on the live path. Document this so no one looks for a `transcribe([Float])` method.
- `TranscriptResult.is_partial` (`provider.rs:45`) is **dropped from the public result**: the file path keeps only `isFinal` results (`Entry.swift:200`, `Transcribe.swift:149`); the live path surfaces finality by *emitting only finalized segments* (volatile results consumed internally per the `RecognizingSpeechInLiveAudio` "replace by overlapping `audioTimeRange`" pattern, `swift-migration-plan.md:174`) — a documented Swift↔Rust delta.

### 2.3 `SpeechTranscriberProvider` — the adopted conformer (Slice C file / Slice E live)

Absorbs the S2 spike's whole-file driver (`Entry.swift`) + apple-helper's in-process usage (`Transcribe.swift`). One conformer, two entrypoints. Symbols reused verbatim from the **verified macOS-26-SDK swiftinterface lists** in the reference files' headers (`Transcribe.swift:17-37`, `EnsureAssets.swift:19-30`) — do not re-derive them:

| Concern | Reference | Swift |
|---|---|---|
| Availability gate | `SpeechTranscriber.isAvailable` (`Probe.swift`, `Transcribe.swift:84`) | `isAvailable()` false → `.providerUnavailable` on transcribe |
| Locale resolve | `supportedLocale(equivalentTo:)` + `installedLocales` (`Transcribe.swift:104-108`) | `STTLocale.resolve(_:)` (§2.4) → `.assetsNotInstalled` if missing |
| Build transcriber | `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with `[.audioTimeRange, .transcriptionConfidence]` (`Entry.swift:163-168`) | same options set |
| Whole-file analyze | `analyzer.analyzeSequence(from: AVAudioFile)` → last sample time → `finalizeAndFinish(through:)` / `cancelAndFinishNow()` (`Entry.swift:244-249`) | `transcribe(fileURL:language:)` |
| Drain results | `for try await result in transcriber.results { guard result.isFinal … }` in a child `Task` returning its collected value (no mutable outer capture) (`Entry.swift:194-217`) | same Sendable-clean collector pattern |
| Live feed | `analyzer.start(inputSequence:)` + `AnalyzerInput(buffer:)` + `finalizeAndFinishThroughEndOfInput()` (`Transcribe.swift:165-170`) | `transcribe(liveInputs:language:)` |
| Format convert | `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` + `AVAudioConverter` (`Transcribe.swift:257-294`) | reused for the live path if capture's format differs |

**`DictationTranscriber` is NOT used** as a plain config: S2 scored it 0.448 core WER vs SpeechTranscriber's 0.234 (`swift-migration-plan.md:94`, `stt-eval/results/COMPARISON.md`) — it drops 35-45% of conversational content. The plan **may** note `.progressiveLongDictation` as the live-path option per the `RecognizingSpeechInLiveAudio` sample (`swift-migration-plan.md:174`), but the recorded-file path this stint verifies uses `SpeechTranscriber` (the proven S2 config).

### 2.4 Locale resolution (`STTLocale`, Slice A/B — pure-ish)

Ports `Transcribe.swift:100-113` exactly (the sentinel mapping is the load-bearing bit that made "auto" work in the sidecar):
- `""` / `"auto"` / `"auto-translate"` (case-insensitive) → `Locale.current` — Whisper/Parakeet auto-detect sentinels, meaningless to a real `Locale` (`Transcribe.swift:94-99`). Mirrors what `EnsureAssets`/`Probe` install/probe.
- otherwise → `Locale(identifier: id)`, then `SpeechTranscriber.supportedLocale(equivalentTo:)`.
- **no supported equivalent → `.unsupportedLanguage(id)`** (honest — ~30 locales vs Whisper's ~99, `swift-migration-plan.md:90`; never faked with a wrong-language transcript).
- supported but not installed → `.assetsNotInstalled(locale:)` (caller can drive `SpeechAssetManager.install`).

The pure sentinel-mapping (`resolveRequestedLocale(_:) -> Locale`) is headlessly testable; the `supportedLocale`/`installedLocales` async calls are device/asset-gated.

### 2.5 The model-download / asset manager (`SpeechAssetManager`, Slice B — absorbs `EnsureAssets.swift`)

```swift
public struct SpeechAssetManager: Sendable {
    /// ← Probe.checkSpeechAvailable. Sync `SpeechTranscriber.isAvailable`.
    public func isEngineAvailable() -> Bool
    /// ← Probe.checkSpeechAssetsInstalled. Membership in `installedLocales` by BCP-47 id.
    public func areAssetsInstalled(forLocale: String?) async -> Bool
    /// ← EnsureAssets.run (EnsureAssets.swift:78). On-demand install with REAL progress: honest 0.0
    /// floor, the framework's own `Progress.fractionCompleted` verbatim, verified 1.0 only after a
    /// real `installedLocales` re-check (EnsureAssets.swift:130-165). Already-installed → single 1.0.
    public func install(forLocale: String?, onProgress: @escaping @Sendable (Double) -> Void) async throws
}
```

**What dissolves vs. needs code (§9(2)):** the Rust `whisper_engine`/`parakeet_engine` download managers fetched multi-GB weights from Hugging Face into the app-data dir and managed their lifecycle. Under SpeechAnalyzer those assets are **OS-managed** — `AssetInventory.assetInstallationRequest(supporting:)` + `downloadAndInstall()` (`EnsureAssets.swift:118,149`) hand the download to the system; **no HF URL, no model-dir bookkeeping, no cache eviction** to port (subsystem-map "Partly dissolves", `swift-migration-plan.md:243`). What still needs code is exactly `EnsureAssets.swift`: availability gate, locale resolution, install request + KVO `Progress` observation, post-install verification. WhisperKit/MLX would reintroduce a managed downloader — a reason to keep them out of scope (§9(1)).

## 3. Concurrency model (Swift 6 strict)

- **`SpeechAnalyzer` is an `actor`** (`Transcribe.swift:26`), used from `async` contexts off the main actor. `SpeechTranscriberProvider` is a `Sendable` struct holding only immutable config — no shared mutable state, no `@unchecked Sendable`, no `nonisolated(unsafe)` (same posture as `AppleNLEmbedder.swift` and the provider layer, `arikit-engine-providers.md §3`).
- **The results-drain pattern is the S2 spike's Sendable-clean one** (`Entry.swift:194-217`): a child `Task` that *returns its collected value* rather than mutating an outer `var` — reuse it verbatim, it's the reference for draining `transcriber.results` without a concurrency warning.
- **Hot-path guarantee — STT must never block capture.** On the live path, capture pushes decoded buffers into an `AsyncStream` continuation **non-blocking** (mirroring the Rust `recording_sender_for_mixed` fork, `open-questions.md` Q2) and the analyzer drains on its own executor. **STT never runs inference on the audio callback/capture thread** — the same rule the F1 contract states ("never do embedding inference inline in that loop", `open-questions.md` Q2). The file path is post-hoc (no real-time constraint).
- **Cancellation → structured concurrency.** `transcribe(fileURL:)` honors `Task.checkCancellation()` and cancels the collector on any thrown error (`Transcribe.swift:171-173`); the live stream cancels its child task via `AsyncThrowingStream` `onTermination` (the `LLMClient.stream` pattern, `LLMClient.swift:44`). No global mutable state.
- **`SpeechAssetManager.install`** forwards KVO `Progress` fractions through an `@escaping @Sendable (Double) -> Void`, observation invalidated in a `defer` (`EnsureAssets.swift:137-144`).
- **No `@unchecked Sendable` / `nonisolated(unsafe)`** anywhere.

## 4. Persistence

**STT itself is stateless — no schema, no writes.** It emits `[TranscriptionSegment]` (mirrors the provider layer being stateless, `arikit-engine-providers.md §3`), keeping it capture-agnostic and usable by the eval harness without a DB.

**The mapping is a pure function** (`TranscriptMapping`, Slice D): `TranscriptionSegment → AriKit.Models.Transcript` (`Transcript.swift:18`) — fresh `TranscriptID`, the `MeetingID`, `transcript = segment.text`, `audioStartTime = segment.startSec`, `audioEndTime = segment.endSec`, `duration = endSec - startSec`, `speakerId = nil` (diarization is Phase 3.5; the field is explicitly `nil` until a voiceprint resolves it, `Transcript.swift:33`), and `timestamp` set from the segment start as an `MM:SS` label (the recall chunker expects an `[MM:SS]`-derivable label, `Chunker.swift`). The Rust worker computed `audio_end_time = chunk_timestamp + chunk_duration` from VAD windows (`worker.rs:203`); here the times come from `SpeechTranscriber`'s real `result.range` — more accurate.

**The DB write is the capture orchestrator's job (Phase 3.2), through repositories only** (principle 3; one owner = `AppDatabase`, `AppDatabase.swift:18`). `TranscriptRepository.upsert(_:)` exists and takes one `Transcript` (`TranscriptRepository.swift:40`). **Additive Store hand-off (deferred to Phase 3.2, like `meetingParticipant` in `arikit-engine-providers.md §4`):** a full recording produces dozens–hundreds of segments; add an additive `TranscriptRepository.upsert(_ transcripts: [Transcript])` writing the batch in **one** `dbWriter.write` transaction — added *when Phase 3.2 needs it*, not in this stint (STT writes nothing). Also record provenance: `Meeting.transcriptionProvider = provider.providerName` (`Meeting.swift:26-27`), matching the shipped summary-provenance pattern.

Single-DB-owner reasserted: no second connection, no raw SQLite handle in STT or the harness — the harness reads the *legacy* DB read-only (as `stt-eval/lib/db.mjs:20-24` does) and never touches the AriKit store.

## 5. Dependency-ordered slice plan

**SLICE A — Protocol + value types + stub (START NOW; pure, no deps).** `STT` namespace, `TranscriptionProvider`, `TranscriptionResult`/`TranscriptionSegment`/`WordTiming`/`TranscriptionError`, `STTLocale.resolveRequestedLocale(_:)` (pure sentinel mapping), `CMTimeMapping.seconds(_:)` (pure `CMTime`→`Double` guard, ← `Entry.swift:97-100`), `StubTranscriptionProvider` (`#if DEBUG`, canned segments — mirrors `StubLLMClient.swift:13`). Headless `swift test`-able. Lets the Phase-3.2 orchestrator + the eval harness be written against the stub.

**SLICE B — `SpeechAssetManager`** (absorbs `EnsureAssets.swift` + `Probe.swift` asset half). Availability/installed-locale/install-with-honest-progress. Pure locale logic headless; framework calls device/asset-gated (Lane 2).

**SLICE C — `SpeechTranscriberProvider` recorded-file path (THE VERIFIED PATH).** `transcribe(fileURL:language:)` + segment/word/confidence extraction (`CMTimeMapping` full impl). The S2 driver (`Entry.swift`) as a product conformer. Depends on A + B. Real-audio smoke under `swift test` if assets installed, else honest skip.

**SLICE D — `TranscriptMapping` (pure).** `TranscriptionSegment → Models.Transcript`. Depends on A + `Transcript.swift`. Headless. Flags the additive batch-upsert hand-off (§4) for Phase 3.2.

**SLICE E — `SpeechTranscriberProvider` live-stream interface (DESIGNED, not verified).** `transcribe(liveInputs:language:) -> AsyncThrowingStream<TranscriptionSegment, Error>` over `analyzer.start(inputSequence:)` + `AnalyzerInput` (`Transcribe.swift:165-170`). Compiled + unit-tested for shape/cancellation against a synthetic `AnalyzerInput` sequence; **real mic verification is Phase 3.2** (TCC-gated). Landing the interface now gives 3.2 a stable seam.

**Ordering:** **A** → **B**/**D** (independent) → **C** → **E**. C is the long pole for the gate. (Harness/Slice F is main-loop-side per §11 — not a subagent slice.)

## 6. Test lanes — the explicit headless-vs-device split

Mirrors the MLX build-lane split (`arikit-engine-providers.md §8`), but the axis is **assets/device**, not Metal-toolchain — `SpeechAnalyzer` is a system framework, so most of it runs under **plain `swift test`** on this macOS 26 machine.

**Lane 1 — Headless `swift test` (no assets, no audio):**
- `STTSendableInventoryTests` — every public STT type `Sendable` (compile-time `requireSendable`, ← `ProviderSendableInventoryTests.swift:17` / `RecallSendableTests.swift:11`).
- `STTLocaleTests` — sentinel mapping (`""`/`"auto"`/`"AUTO"`/`"auto-translate"` → `Locale.current`; `"en-US"` → `Locale("en-US")`; ← `Transcribe.swift:100-103`).
- `CMTimeMappingTests` — invalid/indefinite `CMTime` → 0 (← `Entry.swift:98`); valid range → correct seconds; per-run extraction from a **hand-synthesized `AttributedString`** carrying `.audioTimeRange`/`.transcriptionConfidence` runs → correct `[WordTiming]` + mean confidence (no live model — exactly how `FoundationModelsClientTests` builds inputs without a live session).
- `TranscriptMappingTests` (D) — segment→`Transcript`: times/duration/`speakerId==nil`/`MM:SS` label; empty-text segment → empty-transcript row verbatim (No-Fake-State — silence is a real outcome, ← `Transcribe.swift:185-188`).
- `StubTranscriptionProviderTests` — deterministic segments + error injection (← `StubLLMClientTests`).
- `TranscriptionErrorTests` — availability/asset/unsupported-locale via an **injected-seam** provider (closures for `isAvailable`/`installedLocales`, the exact `FoundationModelsClient` `unavailableReason`/`respond` pattern, `FoundationModelsClient.swift:76-84`): unavailable → `.providerUnavailable` and the transcribe closure is **never** called (asserts no fabricated text, ← `FoundationModelsClientTests.swift:30-33`); unsupported → `.unsupportedLanguage`; resolvable-but-missing → `.assetsNotInstalled`.

**Lane 2 — Real-audio, asset-gated (runs under `swift test` if assets present AND a fixture is present; honest skip otherwise):**
- `SpeechTranscriberSmokeTest` — locates an OPTIONAL real-speech WAV (env var `ARIKIT_STT_SMOKE_WAV`, or a conventional path) → `transcribe(fileURL:)` returns ≥1 finalized segment with non-empty text, word count > 0, `startSec < endSec ≤ audioDurationSec`. **No audio is committed** (§11 privacy ruling). **Fallback:** if `SpeechAssetManager.areAssetsInstalled` is false OR no fixture is present, record a `withKnownIssue`/skip with an honest message — **never fakes a pass** (No-Fake-State).

**Lane 3 — The S2 accuracy gate + long-file check (MAIN-LOOP-SIDE, out-of-suite — §11):** the quality bar — run by the main loop at the final gate via a harness built outside the AriKit package (§8), needing `~/Movies/meetily-recordings/*/audio.mp4` + the legacy DB + Python `jiwer`. The **dual-run gate** (principle 2), analogous to the S1 gate in `arikit-engine-providers.md §6`.

## 7. Invariants preserved (principle 6)

- **No-Fake-State (the load-bearing STT invariant).** Every segment reflects a REAL transcription; on ANY failure (engine unavailable, assets missing, decode error, empty/short audio, thrown error) the provider **throws** a descriptive `TranscriptionError` — never fabricates text or a confidence value. `Transcribe.swift`'s exact discipline (`:11-15,84-88,109-113,118-120`) ported as the provider contract; `EnsureAssets.swift`'s honest-progress discipline (`:11-17,157-161`) ported into `SpeechAssetManager` (real 0.0 floor, framework's own fractions, verified 1.0 only after a real `installedLocales` re-check). Confidence `nil` when the SDK gives none, never invented (`Transcribe.swift:160`). Empty finalized text for silence returned verbatim (`Transcribe.swift:185-188`). Tested Lane 1 + Lane 2 (skip-not-fake).
- **Consent-before-record.** STT never initiates capture — it consumes a file URL or a caller-owned stream; the consent gate is the capture layer's (Phase 3.2). STT structurally cannot record silently.
- **Swift 6 strict concurrency** — no `@unchecked Sendable`/`nonisolated(unsafe)` (§3).
- **Single DB owner** — STT writes nothing; persistence is via `TranscriptRepository`/`AppDatabase` at the capture layer (§4); the harness reads the legacy DB read-only.
- **Latest-OS-only (principle 7)** — macOS/iOS 26 floor pinned (`Package.swift:50-53`); `Speech` imports with no `@available` shims.
- **Not STT concerns (noted):** loopback-only / bounded-context / never-invents-citations are recall/summary invariants, unaffected.

## 8. The acceptance / gate procedure (Lane 3 — THE quality gate; main-loop-side)

**The gate is the S2 rig accuracy metric, NOT 1:1 Rust unit-test parity** (STT dissolves, §0). Reproduces S2 (`swift-migration-plan.md:94`) in the product path. **Executed by the main loop at the final gate** (§11), against the real recordings (read-only, never committed).

1. **Drive AriKit STT over the 5 held-out meetings.** A thin harness (built main-loop-side, outside `AriKit/Package.swift`) resolves each meeting's audio via `folder_path` from the legacy DB read-only (the `SELECT id, title, folder_path FROM meetings` + `<folder_path>/audio.mp4` pattern of `stt-eval/lib/db.mjs:48`), for the 5 IDs in `stt-eval/extract_parakeet.mjs:8-14` (`nia`, `career_1on1`, `metro2`, `servicing_org`, `brian1on1`). It calls AriKit's `SpeechTranscriberProvider.transcribe(fileURL:language:"en-US")` and emits `tools/stt-eval/results/speechanalyzer/<key>.transcriber.json` in the **exact S2 shape** — `{mode, locale, input_path, text, segments:[{text,start,end,confidence?}], wall_ms, word_timestamp_count, segment_count, audio_duration_sec, error?}` (verified against `results/speechanalyzer/nia.transcriber.json` + `Entry.swift:41-61`). `AVAudioFile` opens `audio.mp4` directly, so **no ffmpeg pre-decode** (`Entry.swift:15`).
2. **Score.** `cd tools/stt-eval && uv run --with jiwer python3 score.py` (`score.py:26`) — the *committed, unchanged* rig scores against the committed Whisper-large-v3 pseudo-reference (`results/reference/*.json`) and the committed Parakeet baseline (`results/parakeet/*.json`).
3. **Pass bar (meet-or-beat, principle 2) — on the AGGREGATE MEAN, not strict per-meeting-beat** (gated §11(c)). SpeechTranscriber genuinely *loses* to Parakeet on `metro2` core WER (0.277 vs 0.249, `COMPARISON.md`) — a documented exception; the win is in aggregate:
   - **`mean_wer_core(sa_transcriber) ≤ mean_wer_core(parakeet)`** — i.e. **≤ ~0.2814** (frozen Parakeet baseline, `COMPARISON.md`), reproducing the S2 spike's **~0.234** within tolerance (±0.02, for the mp4-vs-WAV input difference).
   - **word-timestamp coverage ≈ 1.0** on every meeting (`score.py:279-284`) — proves segment/word extraction is wired.
   - **punctuation present** (`punct_count > 0`, `score.py:76`) on every meeting.
4. **The 60-80 min long-file check (the explicit S2 caveat).** S2 only verified whole-file no-chunking to ~45 min. Exercise `brian1on1` (~80 min, `score.py:50`) and assert it is **not silently truncated**: `segments.last.end ≈ audioDurationSec` (within a few seconds), where `audioDurationSec = AVAudioFile.length / sampleRate` (`Entry.swift:140`), **not** the DB's `MAX(audio_end_time)`. ⚠️ **Two meetings carry a pre-existing 2× `audio_end_time` DB bug** (`swift-migration-plan.md:94`) — a DB-derived duration would be wrong; use the real file duration and do **not** mistake that data bug for a port regression.

**Spike gate = S2 (GO-with-caveats, already passed).** If the product path regresses below baseline, `SpeechTranscriberProvider` stays behind the protocol and the fallback is **WhisperKit** (S2 fallback candidate) as a separate target (§9(1)) — the Rust engines are *not* resurrected (native-first, `swift-migration-plan.md:140`). Nothing else in Phase 3 blocks: recall + summary are green; capture (3.2) feeds either backend through the same protocol.

## 9. Open decisions — recommendations (see §11 for the RESOLVED gate)

1. **`TranscriptionProvider` protocol shape + WhisperKit scope.** *Recommend:* the **segment-emitting** protocol (§2.2), two entrypoints (file verified, live designed). **DEFER WhisperKit** — it adds an SPM dep and reintroduces the managed downloader SpeechAnalyzer's OS-managed assets dissolve (§2.5); S2 is GO on SpeechTranscriber. Keep the protocol WhisperKit-ready; if ever added, isolate in `AriKitEngineWhisperKit` exactly as MLX→`AriKitEngineMLX` (`arikit-engine-providers.md §8`).
2. **`SpeechAssetManager` surface + what dissolves.** *Recommend:* the §2.5 surface, absorbing `EnsureAssets.swift` + `Probe.swift` in-process (the sidecar hop vanishes, as `AppleNLEmbedder` did). HF download + model-dir lifecycle **dissolve** (OS-managed).
3. **Test lanes.** *Recommend:* the §6 three-lane split — Lane 1 fully headless (injected seams), Lane 2 a real-audio smoke that honest-skips when assets/fixture absent, Lane 3 the manual S2 gate.
4. **Eval harness form.** *Recommended by architect:* an `executableTarget` in `Package.swift`. **OVERRIDDEN at gate (§11):** built main-loop-side, outside the package. Package.swift untouched.
5. **Additive `TranscriptRepository` batch-upsert.** *Recommend + gated:* add `upsert(_ transcripts: [Transcript])` **when Phase 3.2 wires capture→persistence**, not this stint (STT is stateless).

## 10. Risks & sequencing

- **STT quality regression (S2 caveat is real).** Mitigated by the §8 gate on the committed rig (0.234 vs 0.281 aggregate win). A per-meeting loss on `metro2` is expected — do not mis-gate on strict per-meeting-beat.
- **Long-file truncation (only ~45 min verified in S2).** §8 step 4 exercises `brian1on1` (~80 min) and asserts `last.end ≈ real file duration` (via `AVAudioFile`, never the buggy DB `audio_end_time`). If SpeechAnalyzer truncates long files, the fallback is windowed feeding on the live path — but verify no-chunking first.
- **Locale coverage delta (~30 vs ~99).** A genuine narrowing vs Whisper — surfaced as `.unsupportedLanguage` (§2.4), never a wrong-language transcript.
- **Live path unverified until 3.2** — by design; the interface (Slice E) lands now so capture has a stable seam. Don't let 3.2 pull scope into 3.3.
- **Asset-gated CI flakiness** — Lane 2's honest-skip keeps `swift test` green on a bare machine; the real check is Lane 3 + Lane 2 on a provisioned machine.
- **Schema/behavior drift vs. frozen Rust** — low (frozen; STT dissolves rather than mirrors); re-check if an STT bugfix lands Rust-side during transition.

Ordered, each independently testable, all Swift-side: **A** → **B**/**D** → **C** → **E**. If the S2 gate regresses, `SpeechTranscriberProvider` stays behind the protocol and WhisperKit is added in its own target (§9(1)) — the Rust STT engines are not resurrected.

## 11. Gate decisions (main loop, 2026-07-20) — AUTHORITATIVE

The plan is **approved** with the following resolutions. Where these differ from §9, these win.

1. **Protocol shape + WhisperKit — APPROVED as specified.** Segment-emitting `TranscriptionProvider` with file (verified) + live (designed) entrypoints. **WhisperKit DEFERRED** — protocol stays backend-agnostic; if added later, isolate in its own target (never pull the dep into core `AriKit` this stint).
2. **`SpeechAssetManager` — APPROVED as specified** (§2.5). Absorb `EnsureAssets`+`Probe` in-process; OS-managed assets dissolve.
3. **Test lanes — APPROVED with a privacy tightening.** Lane 1 (headless, injected seams) + Lane 2 (asset-gated real-audio smoke) are **built by the implementation subagents inside `AriKit/Tests/**`**. **Privacy ruling: subagents commit NO audio.** The Lane-2 smoke honest-skips unless BOTH the SpeechTranscriber assets are installed AND an *optional, uncommitted* WAV is present (env var / conventional path). Never fabricate a pass. (Rationale: the eval meetings are private — memory has flagged private-content risk on this set; no audio of uncertain provenance enters the repo.)
4. **Eval harness — OVERRIDE: main-loop-side, `Package.swift` UNTOUCHED.** The accuracy gate (Lane 3 / §8) is **my** final-gate job, not an implementation slice. I build the measurement harness *outside* the AriKit package (a local throwaway SwiftPM package depending on `AriKit` by path, reusing the S2 spike's JSON shape) so `AriKit/Package.swift` stays pristine and the throwaway rig never becomes a shipping target. **Subagents do NOT touch `Package.swift` and do NOT add an eval target.** Consequently there is no "Slice F" for the subagents — slices are **A → B/D → C → E** only.
5. **Pass bar — APPROVED: aggregate-mean.** `mean_wer_core(SpeechTranscriber) ≤ Parakeet baseline (~0.2814)`, reproducing ~0.234 within ±0.02. Per-meeting losses (e.g. `metro2`) are expected and do NOT fail the gate — strict per-meeting-beat would wrongly reject the S2-proven engine. Plus: word-timestamp coverage ≈ 1.0 and punctuation present on every meeting, and the `brian1on1` ~80-min no-truncation check (via real `AVAudioFile` duration, never DB `audio_end_time`).
6. **Batch `TranscriptRepository.upsert([Transcript])` — DEFERRED to Phase 3.2.** STT is stateless this stint; do not add the Store method now (flagged so 3.2 owns it).

**Scope for the implementation workflow:** edit ONLY `AriKit/Sources/AriKit/Engine/STT/**` and `AriKit/Tests/AriKitTests/Engine/STT/**`. No `Package.swift`, no new dependency, no Rust/frontend, no committed audio. Slices A → B/D → C → E, each `swift build` + `swift test` green (Lane 1 always; Lane 2 honest-skips). Agents do NOT commit.
