# Swift-Native Migration Plan

**Date:** 2026-07-16 (v3 — directional revision by Paul: **Mac migrates and finishes first; the mobile "lite" app is a separate later project (Phase 6), scoped as the full app minus speaker identification, not a read-only viewer; CloudKit sync infrastructure still lands early.** Supersedes v2's "results-layer / mobile-first" phasing. v2's framework fact-checks, codebase-grounding audit, and architecture critique all still stand and are retained below.)

A staged plan to migrate Ari from its current Rust/Tauri + Next.js polyglot stack to a **100% Swift, Apple-only** codebase — and, in doing so, lay the foundation for an Apple multi-device product family. The **macOS app is migrated first and finished first**; a mobile ("lite") app on iOS/iPadOS is a **separate, later project built on the finished `AriKit`** once the Mac migration is complete (see Phase 6). "Lite" does **not** mean read-only: the mobile app aims for **the same feature set as the Mac app minus speaker identification** (F1) — recording, transcription, and summarization run on-device there too — because on-device speaker diarization/re-ID has no proven mobile model yet (revisit if one is found). Text results sync across devices through iCloud; audio stays on the device that recorded it.

Companion docs: `plans/leverage-apple-models.md`, `plans/diarization-production-plan.md`, `.claude/context/architecture.md`, `meeting-intelligence-prd.md`.

## Verdict

**Migrate — but as a strangler, not a big-bang rewrite.** The decisive reasons are Apple-only intent + the eventual iCloud/mobile-app capability, which the current stack is structurally bad at (no CloudKit from Rust; the heavy engine — a Rust/C++ polyglot — can't be shared with a native iOS app anyway). Most of the C/C++ engine surface *dissolves* into native frameworks (MLX, SpeechAnalyzer, Core Audio process taps, AVAudioEngine, AVFoundation, GRDB) rather than needing re-wrapping — the notable exception, diarization/re-ID, already has a scoped Swift path (**FluidAudio**, CoreML pyannote, offline DER ~10.6% on AMI).

The multiplier: **we have a ~90%-finished product**. This is a second-system rewrite *with the full spec already in hand* — every behavior, edge case, and quality bar is known and encoded in working code and tests. That removes the usual rewrite risk (discovering requirements late) and lets us hold each Swift component to a measured bar before it replaces its predecessor.

**Honest scope numbers** (measured 2026-07-16): the Rust engine is **~62k lines** (196 files) — *larger* than the **~42k-line** React/BlockNote UI (243 files). "Dissolves into frameworks" is an argument about *effort*, not lines: much of that Rust exists to bridge APIs Swift calls natively. But the engine port is the bulk of the calendar time, and this plan quantifies it (see the subsystem map) instead of hand-waving it.

The two things a rewrite does **not** make cheaper, and where the real months go:
1. The **~42k-line React UI** — specifically its *block-editor* layer. (Correction from v1: as of macOS/iOS 26, SwiftUI `TextEditor` binds `AttributedString` natively with selection + formatting — plain rich text is no longer hard. What has no native equivalent is BlockNote-style **block editing**: drag handles, slash menus, and our ProseMirror `@ref` badge decorations. That layer migrates **last**, possibly living in a scoped WebView longest.)
2. **Diarization/re-ID** — a real model-port effort in any language.

## Guiding principles

1. **Strangler, never big-bang.** The current app stays shippable and usable the entire way. We stand up a native shell and replace pieces behind it; nothing is deleted until its replacement beats it.
2. **Quality gates before commit, dual-run first.** No engine component is swapped until the Swift version **meets or beats** the incumbent on a fixed eval set. For each port: the invariant/acceptance suite is written (or committed) *first*, run green against the **Rust incumbent**, then against the Swift candidate. ⚠️ Prerequisite: the prompt-validation harness lives only in project memory today and the diarization sweep scripts are uncommitted scratchpad — **committing both into `tools/` is Phase-0 work item P0**, or gates S1–S3 have nothing to measure against.
3. **Exactly one process owns the database at any time.** Everyone else (sidecars, the Swift shell before cutover, the CloudKit publisher) goes through the owner's API. No cross-process dual-ORM WAL writes (sqlx + GRDB on the same file is a lock-contention/corruption footgun, and sqlx's `_sqlx_migrations` table is invisible to GRDB). CloudKit sync cursors/state belong to the DB owner too.
4. **Mac first, mobile last — but sync-ready from the start.** The macOS Swift migration runs to completion *before* the mobile app is built (Phase 6). The mobile app is a separate, later project on the finished `AriKit`, not an early parallel deliverable. What *does* land early is the **sync infrastructure**: the CloudKit-capable store and results schema are built during the Mac migration (they shape the schema and cost little once SQLiteData is in) so that when the mobile client arrives it consumes an already-proven sync layer rather than forcing a schema change late.
5. **Sync text, keep audio local.** Transcripts/summaries/metadata are small and sync freely via CloudKit; meeting audio is large (we've hit 138 MB files) and stays on the device that recorded it (fetched on demand as a `CKAsset` only if ever needed). Since the mobile app records on-device too, "local" means device-local on both Mac and phone — sync is bidirectional for text, never for audio.
6. **Preserve the invariants.** The recall safety shell (loopback-only local path, bounded context, never-invents-citations — enforced by the existing `recall/` unit tests), consent-before-record, and the design system's No-Fake-State rule survive the port verbatim, as ported Swift test suites (swift-testing/XCTest), not just intentions.
7. **Latest-OS-only is an accepted constraint.** SpeechAnalyzer + FoundationModels are macOS/iOS 26+; Core Audio process taps need macOS 14.4+; MLX needs recent Apple Silicon. For a private single-user product this is fine — but it's a hard floor we commit to openly.
8. **WIP limits — the strangled tree must not outgrow the strangler.** At most **one migration phase active** at a time, and at most **one product feature in flight** concurrently — and that feature lands on the *target* side of any seam already cut (once the Swift store exists, new tables go into GRDB only; once the shell exists, new UI goes SwiftUI-first). Features still deep in Rust (F1–F4) get finished on the current stack, then the Rust engine freezes except bugfixes; F5/F8-class net-new work goes Swift-native.

## Target architecture (end state)

A single **Swift Package** of shared domain code, consumed by two app targets. **The macOS target is built and finished first; the iOS target (Phase 6) reuses as much of the shared engine as the platform allows — everything except speaker ID.**

```
AriKit  (shared Swift package)
├── Models        meetings, transcripts, summaries, persons, series, profile facts
├── Store         GRDB (local source of truth)  +  CloudKit sync (results layer)
├── Recall        hybrid retrieval (BM25 ⊕ vector RRF), safety shell + tests preserved
├── Context       SummaryContext assembly (owner + attendees + call type)
└── Engine        capture-agnostic STT / summary / persons / series / recall
                  (shared by both targets; diarization is macOS-only)

Ari (macOS app target — FIRST)               Ari Lite (iOS / iPadOS target — LATER, Phase 6)
├── Capture   Core Audio process tap (sys) + ├── Capture   AVAudioEngine mic
│             AVAudioEngine (mic)            │             (no system-audio process tap on iOS —
├── Encode    AVFoundation (AAC), replaces   │             see open platform deltas below)
│             the ffmpeg sidecar             ├── Encode    AVFoundation (AAC), shared
├── STT       SpeechAnalyzer / WhisperKit    ├── STT       SpeechAnalyzer / WhisperKit (shared)
├── Diarize   FluidAudio (CoreML, offline)   ├── Diarize   ✗ none (no proven mobile model yet)
├── Summary   MLX (Qwen-4B / Gemma-E4B) /    ├── Summary   MLX Gemma-E2B/E4B (128K) /
│             cloud / Claude CLI; FM floor   │             cloud  (tiered to device RAM)
├── Calendar  EventKit                       ├── Calendar  EventKit
├── Notch     (ari-notch UI absorbed)        ├── Recall / persons / series (shared)
└── SwiftUI UI (full)                        └── SwiftUI UI (full, minus speaker labels)
```

`#if os(macOS)` gates the **Mac-only** engine pieces — the system-audio process tap and diarization/re-ID — while the shared `AriKit.Engine` (STT, summary, persons, series, recall, context) compiles for both targets. Cloud providers (Anthropic/OpenAI/Groq/OpenRouter) port trivially over URLSession on both platforms; **exception: the Claude CLI provider is a subprocess wrapper around the local `claude` binary, not HTTP** — it ports as a `Process` spawn, and only on macOS (no subprocess spawning on iOS).

**Open platform deltas for the mobile app (resolved in Phase 6, flagged now so the shared engine is designed for them):**
- **System-audio capture — CONFIRMED macOS-only, not an open question (verified 2026-07-16, incl. WWDC 2026 / iOS 27).** The Core Audio process tap is macOS-only (introduced macOS 14.2; never ported to iOS), and iOS sandboxing forbids capturing other apps' audio output. **WWDC 2026 / iOS 27 did not change this** — the iOS 26 recording additions (input-device picker, `bluetoothHighQualityRecording`, simultaneous record+process) are all mic-side, and WWDC26's audio work (Music Understanding, NowPlaying) is analysis/playback, not capture. The *only* iOS path to another app's audio is a **Broadcast Upload Extension** (ReplayKit) — a separate process, ~50 MB memory cap, Control Center-driven UX — unsuitable for silently capturing the far side of a Zoom/Teams call. **Consequence:** the mobile app is **mic-first by hard constraint** — it captures in-room/local audio well, but cannot capture the remote side of a call the way the Mac's process tap does. This is a genuine feature gap *beyond* speaker ID. Re-check each WWDC for a new iOS capture API before Phase 6; absent one, scope the mobile app as mic-first (in-person meetings + the local speaker's side of calls). Ref: `capturing-system-audio-with-core-audio-taps` (Apple docs, macOS-only).
- **On-device summary model** — MLX runs on iOS with tighter memory than a Mac, but **Gemma 4 E2B (~1.5 GB @4-bit, 128K ctx) fits comfortably on phone** and E4B (~5 GB) on higher-end devices, so robust on-device mobile summarization is viable — not forced onto FoundationModels/cloud. Exact mobile default (E2B vs E4B vs cloud) tuned to real device memory at Phase 6; the tiered engine abstraction is built on the Mac side first.
- **Speaker ID** — excluded by design (no proven on-device mobile diarization model). Revisit if FluidAudio/CoreML pyannote is shown viable on an iPhone/iPad, or a lighter model appears.

## Phase 0 — De-risk spikes (go / no-go gate)

Run these **before** committing to the migration. Each is a throwaway spike measured against real recordings from the existing SQLite DB. **Timebox: 2–3 weeks total, written go/no-go at the end.**

**P0 (prerequisite): commit the eval rigs.** Bring the prompt-validation harness out of project memory into `tools/prompt-harness/`, and commit the diarization sweep scripts (`run_sweep.py`, `postmerge.py`, etc.) plus pointers to the calibrated recordings. Without this, S1–S3 have no measuring stick.

| Spike | Question | Pass bar |
|---|---|---|
| **S1 — on-device summary** | Which on-device Swift model best matches the Qwen-4B GGUF baseline? Bake off the candidates through the committed prompt-harness (each is just a `run({system,user})→{text}` backend): **(a) MLX Qwen-class 4B** (same modeling we ship today, pulled into Swift); **(b) Gemma 4 E4B** (~4.5B eff, **128K ctx**, native **MLX-swift**, ~5 GB @4-bit) and **E2B** (~2.3B eff, 128K ctx, ~1.5 GB) — the mobile-grade models; **(c) FoundationModels** kept only as a zero-download fallback. **Key finding (2026-07-16):** FoundationModels' 4,096-token shared window (unchanged through iOS 26.4; Apple just throws on overflow) forces map-reduce, which provably sheds the citation/table/per-person granularity Ari depends on — whereas MLX-Qwen and Gemma-128K hold a full meeting in **one pass**. So the real contest is MLX-Qwen vs Gemma-E4B on quality; FoundationModels is a floor, not a contender for the default. | Summaries rated ≥ current on the prompt-harness set (**n=9** real transcripts — Paul accepted 9, no wait for a 10th; blind A/B) |
| **S2 — STT accuracy** | Does SpeechAnalyzer match Parakeet/Whisper-large on real meeting audio? Public benchmarks only show it beating Whisper-*Small*; parity with our Parakeet baseline is **genuinely unproven** — this gate is real, not a formality. Also verify: `.audioTimeRange` word timestamps (final results only), `SpeechDetector` VAD, and the ~30-locale limit vs Whisper's ~99. Fallback candidate: **WhisperKit** (CoreML Whisper — the proven Swift path; MLX-Whisper is not turnkey in Swift). **Correction (2026-07-16): the new framework DOES support a custom language model** — Apple's `RecognizingSpeechInLiveAudio` sample wires `DictationTranscriber(contentHints: [.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)])`, built via `SFSpeechLanguageModel.prepareCustomLanguageModel(...)`. So the earlier "no custom vocabulary" gap is **wrong**: SpeechAnalyzer accuracy on attendee names / domain jargon is *mitigable*, and uniquely so for Ari since we know the room (feed calendar/persons names + recurring terms as the custom LM). Consider a custom-LM S2 variant if the base run loses on names. | WER + punctuation ≥ current on ≥5 held-out meetings of mixed quality |
| **S3 — Diarization port** | Does FluidAudio (CoreML pyannote) hit the DER we get from the tuned sherpa-onnx recipe? Compare **offline pipelines only** — FluidAudio's offline DER is ~10.6% avg (AMI SDM) but its streaming modes are far worse (38–53%); do not gate on streaming. **Ground truth (decided 2026-07-16):** use *verified-correct current-app diarization* as the RTTM reference — extract (start, end, speaker) per transcript row from `meeting_minutes.sqlite`. This makes S3 a **parity-vs-current-shipping** test (the right migration bar), NOT absolute DER against human labels. **Seed reference:** meeting `meeting-d894f3ce-…` "Adhoc with Nia" (2 speakers, ~10 min, Paul confirms correct) — good for building/validating the plumbing, but it's the *easy* end. **Rig-build finding (2026-07-16): the primary metric is `stamp_accuracy`, not raw DER.** The app never adopts diarizer segment boundaries — `stamp_transcripts` (commands.rs) stamps existing transcript rows by max-overlap — so raw DER is inflated by dual-VAD boundary mismatch (the reference uses the transcript's Parakeet VAD; a fresh sherpa run does its own pyannote VAD). On Adhoc Nia a faithful sherpa re-run scored **DER 0.22 but stamp_accuracy 1.0000** (100% of reference speech gets the correct speaker) — zero real label disagreement. So gate FluidAudio on **stamp_accuracy** (what actually determines app output), with DER as a secondary diagnostic. | Primary: **`mean stamp_accuracy(fluidaudio) ≥ mean stamp_accuracy(sherpa)`** on the verified set; DER secondary. ≥ parity on the calibrated recordings **plus ≥3 fresh** — grow past the 2-speaker seed to 3+ speaker / remote-mixed cases before the verdict counts. |
| **S4 — CloudKit / store** | Confirm **SQLiteData** (the chosen store) as load-bearing: prototype a private-DB schema and round-trip a meeting result Mac→iCloud→iOS through SQLiteData's CloudKit sync (queued offline changes, record-level conflict resolution). Validate that raw-SQL recall (FTS5 / sqlite-vec) coexists with the synced tables. | Clean sync of text records; conflict handling sane; recall SQL runs against the synced DB |

**S1 spike result — early GO (2026-07-16):** a throwaway Swift runtime spike (`spikes/mlx-swift-s1/`) proved the actual ship path works. **`mlx-swift-lm` 3.31.4** (note: the version bump *past* the 3.31.3 in issue #282 — 3.31.4 registers `gemma4`/`gemma4_unified` in the `LLMTypeRegistry`) loads and runs **dense Gemma 4 E4B 4-bit** (`mlx-community/gemma-4-e4b-it-4bit`, ~4.8 GB) **stock — no registration shim** — and **Qwen3.5-4B-MLX-4bit**, both text-only. On 2 real meetings × 2 models: **100% citation validity (0 fabricated `@ref`)**, template-conformant, correctly speaker-attributed. Perf: Gemma-E4B ~32 tok/s short / ~21 tok/s long, load ~2.6 s warm. We stayed on the dense E2B/E4B tier and never touched the #282-broken variants (assistant/MTP, 26B MoE, 31B dense). **Two carry-forward gotchas for the Phase-3 port:** (1) set `additionalContext: ["enable_thinking": false]` for Qwen3.x-family (else chain-of-thought leaks into the report); (2) the ship build must use **`xcodebuild`** with the **Metal Toolchain** component provisioned (bare `swift build` produces a binary with no `.metallib` → runtime "Failed to load default metallib"), and the `@main` entry file must **not** be named `main.swift`. *Still pending for a full S1 close:* the human blind A/B (runtime + quality are GO; the human A/B is the last gate).

**S1 quality bake-off — 9 meetings, all 3 backends 9/9 (2026-07-16):**

| Backend | Citation validity | Owner attribution | Grounded names | Gen latency | Peak RAM |
|---|---|---|---|---|---|
| Qwen GGUF (current baseline) | 96.1% | 96.4% (n=28) | 91.3% | 33.2 s wall | — |
| **MLX Qwen3.5-4B-4bit** | **96.7%** | **100% (n=40)** | 91.3% | 27.4 s | 2.37 GB |
| Gemma 4 E4B-4bit | **100%** | 90.9% (n=11) | 82.6% | 22.8 s | 2.56 GB |

Advisory `claude -p` blind judge (NOT the gate, n=9): MLX-Qwen vs baseline **5–4 (even)**; Gemma-E4B vs baseline **1–8 (baseline preferred)**. **Read:** **MLX-Qwen matches the GGUF baseline** on every quality axis, faster, at 2.37 GB — a clean drop-in for the current model *in the Swift path* → **desktop default GO**. **Gemma-E4B** is citation-perfect and fastest but scores lower on owner-attribution/name-grounding and the judge clearly preferred the Qwen outputs — so on the current prompt it's **not** a stronger desktop summary; keep it as the **mobile-tier** candidate (128K ctx, fits a phone) rather than the desktop default. Note MLX-Qwen's 2.37 GB peak *also* fits modern iPhones, so the desktop winner may double as the mobile model — simplifying the tier story (settle at Phase 6). Caveats: MLX sampling can't replicate llama.cpp's `presence_penalty`/`repeat_penalty` (documented asymmetry); Gemma's attribution n=11 is small; the judge is one advisory model over 9 meetings.

**Exit:** S1–S3 decide *whether each engine goes Swift or stays sidecar-bridged*; S4 is a prerequisite for Phase 1 (and passes independently of the engine decision). A miss on S1/S2 doesn't kill the migration — it means that engine stays a Rust sidecar longer while the rest proceeds.

## Phase 1 — Sync-ready store foundation (infrastructure, no mobile client yet)

Stand up the CloudKit-capable store early — it shapes the schema and is cheap once SQLiteData is in — **but do not build the mobile app here.** The mobile client is Phase 6, after the Mac migration completes (principle 4). This phase de-risks the *sync layer*, not the *product*.

- Define the **CloudKit results schema** (mirror of `meetings` / `transcripts` / `summaries` / `persons` / series records — text only; audio stays device-local).
- Establish the **CloudKit sync capability** in the Swift store. **Owner: the Swift store owns CloudKit** (resolved 2026-07-16) — no interim `cloudkit-helper` sidecar, since Swift is the single go-forward track and we won't write sync/conflict logic twice. Per principle 3, sync cursors/state persist via the DB owner, not in a helper's private files.
- **Validate the roundtrip without a mobile client**: Mac → iCloud → a second Mac instance (or a second SQLiteData store bound to the same private DB) proves records sync, offline changes queue, and conflicts resolve. This is exactly spike S4 promoted to real infrastructure.

**Exit:** the store is sync-capable and schema-frozen enough that a future mobile client can attach with no schema surgery. This plants the first durable Swift flag (the store — the dependency hub) with zero risk to the working engine, and means Phase 6's mobile app inherits a proven sync layer instead of building it under time pressure. The native Mac read UI is built fresh in Phase 2 and **later becomes the seed of the mobile app's screens (Phase 6)** — the reuse arrow points Mac → mobile, not the reverse.

## Phase 1.5 — Engine extraction (the seam the whole plan hangs on)

*New in v2 — the v1 plan never answered "where does the Rust engine live once Swift owns the window."* Answer: **the Rust engine becomes a headless daemon** the Swift shell spawns — but that extraction happens *first, inside the Rust tree, in the language we know, with the existing test suite green*, not mid-shell-swap.

- **Audit and shrink the command surface first.** ~140 commands are registered today; dozens are deletable before porting anything (24 inert analytics no-ops, whisper parallel-processing commands unused under Parakeet-default, `test_backend_connection`-style vestiges). Target: a documented list of **~90 live commands + ~30 event channels**.
- Carve `frontend/src-tauri` into **`ari-engine`** — a headless crate owning the DB, the audio pipeline, and the 5 sidecars — speaking a versioned NDJSON-over-stdio (or local-socket) protocol: request/response for commands, push channel for events (live transcript, shutdown progress, download progress), and a streaming variant for recall answers.
- The Tauri host becomes a **thin client** of that protocol: `invoke` handlers forward to the engine; `emit` relays engine pushes. The app must behave identically before/after — this is a pure refactor with an end-to-end test.

**Exit:** the engine runs headless behind a protocol with **two possible clients**. The Swift shell in Phase 2 attaches as the second client — no Tauri machinery to re-implement under time pressure.

## Phase 2 — Native macOS shell (the pivot)

Stand up the **native macOS SwiftUI app** as the new host. It spawns `ari-engine` (which still spawns/owns the existing sidecars) and talks the Phase-1.5 protocol.

**Revised from v1 — native-first, scoped WebView.** v1 hosted the *entire* React UI in a WKWebView behind a full bridge; that bridge would carry ~136 `invoke()` call sites across 39 files, an event push channel used by 25+ files, *and* a byte-range asset protocol — all 100% throwaway. Instead:

- **Read UI goes native on day one**: meetings list, meeting details (read view), people, series. These are the easiest screens — and they are the **seed of the mobile app's UI in Phase 6** (build them well here; the reuse arrow is Mac → mobile). All native SwiftUI is themed **Marginalia from `brand/tokens.json` from the first screen** — the Arivo theme never gets ported to Swift (see Phase 4 for the full design-system spec).
- **A scoped WKWebView hosts only the genuinely-hard screens**: the BlockNote editor panel, settings, and the new-meeting/recording flow — bridging only the **~30–40 commands those screens actually use**, enumerated explicitly before work starts. The bridge needs three pieces, all scoped: (i) `invoke` adapter via `webkit.messageHandlers`; (ii) event push via `evaluateJavaScript` callbacks; (iii) a `WKURLSchemeHandler` with **byte-range support** replacing `convertFileSrc` for audio playback/scrubbing (used by `AudioPlaybackContext.tsx`).
- Native window, menu bar, notifications, tray, and the **notch UI** absorbed (retire the `ari-notch` sidecar's *UI*; note its scheduler/state logic lives in Rust `notch/bridge.rs` and ports with the engine in Phase 3 — the Phase-2 absorption is the panel, not the brain).
- **EventKit calendar moves into the shell now** — `calendar/eventkit.rs` is already native-API code via objc2, it's the cheapest early Swift win, and it's the most TCC-sensitive subsystem, benefiting most from a real bundle identity.
- **Distribution posture pinned: Developer ID signing, hardened runtime, NO App Sandbox** (consistent with personal-use scope; sandboxing would break process-tap audio capture and sidecar model directories; CloudKit works fine under Developer ID with the paid account). New code identity means **one-time re-grant of Mic/Screen Recording/Calendar TCC permissions** — expected, document it, done.
- **Data continuity milestone: "import existing library."** A one-shot migrator that adopts the live app-data dir (`~/Library/Application Support/com.meetily.ai`): SQLite DB (26 migrations of real data), meeting folders + audio files, crash-recovery checkpoints, and the multi-GB downloaded models (Parakeet ONNX, GGUF, embedders) — with post-import verification counts. Settings/API keys: audit where they live (DB vs Keychain); Keychain items are tied to the signing identity/team and can be orphaned by the change.

**Exit:** the app is a Swift host with native OS integration, CloudKit, calendar, and a native read UI; the web UI survives only inside a scoped panel. Tauri is deleted (the engine no longer needs it); Next.js is now a guest in three screens.

## Phase 3 — Engine migration (behind the shell)

Replace `ari-engine` modules with Swift behind the same protocol, each gated on its Phase-0 spike bar. **Revised order — the store moves first** (v1 had it 4th, which forced every earlier Swift piece to write through Rust or open a second WAL connection; the store is the dependency hub and migrating the hub last-but-one was backwards).

1. **Store** — `sqlx` SQLite → **GRDB** (repository pattern maps 1:1; evaluate Point-Free's **SQLiteData** for the GRDB+CloudKit layer — first-class CloudKit sync over SQLite, exactly our "GRDB local + explicit results publish" shape). Port the schema, freeze sqlx migrations at cutover, and port the **hybrid-retrieval recall engine + its safety-shell tests** (loopback-only, bounded context, no invented citations — dual-run per principle 2). Includes the multi-backend embedder plumbing (Apple NLEmbedding default / nomic GGUF / Ollama). From here on, the Rust remainder reads/writes via the Swift store over the engine protocol — **one owner, always**.
2. **Capture + encode** — `cidre`/`cpal` → Core Audio process tap (`CATapDescription` + `AudioHardwareCreateProcessTap`, public API since macOS 14.4 — the same API cidre wraps, so the wrapper literally vanishes) + AVAudioEngine mic + **AVFoundation/AVAudioFile AAC encode replacing the ffmpeg sidecar** (ffmpeg does encoding, mixing, decoding, *and* crash-recovery remux today — all four duties must be replaced, then the sidecar deleted). Known AVAudioEngine gotchas (budget for them; this step is effort-parity with cpal, not free): `installTap` must use the hardware format or it crashes; resample to 48 kHz mono via `AVAudioConverter`; hardware format changes at runtime on device switches (AirPods at 16/24 kHz) — the same device-churn handling `device_monitor.rs` does today. Port VAD (`SpeechDetector` or a small CoreML silero), the incremental saver/crash recovery, import + retranscription, and the notch scheduler.
3. **STT** — Whisper/Parakeet → SpeechAnalyzer (turnkey) and/or **WhisperKit** per the S2 outcome. Already proven once in `apple-helper`. Includes the **model-download manager** (SpeechAnalyzer assets are OS-managed — a chunk of this module dissolves; WhisperKit/MLX models still need managed downloads). **Live-transcription port reference:** Apple's `RecognizingSpeechInLiveAudio` sample (downloaded to `~/Downloads/RecognizingSpeechInLiveAudio`) is the canonical pattern for Ari's live path — `DictationTranscriber(.Preset.progressiveLongDictation)` + `SpeechAnalyzer(modules:)` + `analyzer.analyzeSequence(inputs)`, streaming `transcriber.results` (volatile→final, replace by overlapping `audioTimeRange`), `AssetInventory.assetInstallationRequest(supporting:)` for on-demand model install, and an optional custom LM via `contentHints: [.customizedLanguage(...)]`. Wire the mic input as an `AsyncSequence<AnalyzerInput>` (the sample uses an AVCaptureSession provider; Ari would tap AVAudioEngine + the Core Audio process tap).
4. **Summary** — llama-helper (llama.cpp) → **MLX via `mlx-swift-lm`** / FoundationModels (short contexts only); keep cloud providers (URLSession) and the Claude CLI provider (`Process`). Retire the `llama-helper` sidecar when MLX passes S1. Port the SummaryContext assembly, templates, citations verification (`citations.rs`), and **persons extraction/reconciliation + series detection** engines.
5. **Diarization / re-ID** — sherpa-onnx (`diarize-helper`) → FluidAudio (CoreML, **offline pipeline**). Port the tuned post-merge/floor recipe; this is the hardest step and is scheduled late deliberately. Keep the sherpa sidecar callable as fallback until FluidAudio hits parity on the S3 set. License note: FluidAudio SDK is Apache-2.0 but its pyannote-derived weights are **CC-BY-4.0** (attribution — only matters if distribution ever widens).

**Exit:** all heavy work runs in Swift; the `llama-helper`, `diarize-helper`, and `ffmpeg` sidecars are deleted; the `ari-engine` Rust daemon shrinks to nothing and is retired.

## Phase 4 — UI nativization

Replace the remaining web screens with SwiftUI, driving each from `AriKit` directly. **The real route list is 11, not 6** (v1 undercounted by ~45%): `/`, `/meetings`, `/meeting-details`, `/new-meeting`, `/chat`, `/settings`, **`/calendar`, `/people`, `/person-details`, `/series`, `/series-details`** — though the Phase-2 native read UI already covers several.

**The design system is decided: "Marginalia"** (adopted 2026-07-16, canonical in **`brand/`** — `BRAND.md` + `tokens.json` v1.2.0 + `assets/*.svg`; presentation layer in the Brand Book artifact). The Arivo theme (root `DESIGN.md`/`DESIGN.json`, Signal Desk) does **not** carry over — it remains the enforced, test-fixture system for the Tauri app only, until the web UI is deleted. What the Swift UI builds against:
- **Tokens:** `brand/tokens.json` drives the SwiftUI theme (asset-catalog colors, spacing 4–48, radii 6/10/14) and a ported visual-system test replaces the Arivo one. Two-inks color system: Shin-kai accent `#1B3A8C`/`#7E9BE8` under the ≤8% Signal Rule; Iron Gall `#152C66` heading ink (light) / paper-white (dark).
- **Type:** SF Pro body/UI; **Bricolage Grotesque** (OFL) bundled and used for headings **≥17pt only** (SF Pro Semibold below) — same self-hosted pattern as Space Grotesk today. `Font.custom` + `relativeTo:` for Dynamic Type.
- **Marks:** one drawing everywhere — the R2 "Dictation" gesture as app icon (squircle, paper field) and wordmark; its 16px "signature flick" cut is the menu-bar/notch recording glyph (`brand/assets/`). The old Arivo crescent-ring icon is retired.
- **Carried-over principles** (now brand-wide per `BRAND.md` §"Where the rules apply"): No-Fake-State, two inks, sentence case, warm neutrals, consent voice. "Animate only real state" is the product-surface motion rule.
- **Build-time tuning items** from the brand doc: selection-wash alpha (test 16–18% light mode on a bright display), wordmark re-export with outlined Bricolage once bundled.

- Migrate simplest remaining routes first; leave the **block editor last**. Native path: `TextEditor` + `AttributedString` (macOS 26) covers rich text; the block-editing layer (drag handles, slash menus, `@ref` badge decorations) either gets a native rebuild on that foundation or that one panel stays a scoped WebView longer. Audio playback goes native (`AVPlayer` — no more URL-scheme bridge).
- **MCP extensibility (F8)** lands here (or as the one in-flight feature earlier, Swift-native per principle 8): an MCP server exposing the meeting store binds to `AriKit.Store`/`Recall` — build it against AriKit once, not against Rust first.
- Retire the scoped WKWebView as the last panel lands.

**Exit:** no web UI remains; Next.js, React, and the bridge are removed.

## Phase 5 — Convergence & cleanup

- Fold the Mac engine's models into the shared `AriKit` package so Mac and iOS share one definition (the Phase-1 CloudKit schema converges here).
- Delete the entire Rust tree (`ari-engine`/`frontend/src-tauri` remnants, `llama-helper`, `diarize-helper`) and the `frontend/` web app.
- Delete the root Arivo `DESIGN.md`/`DESIGN.json` along with the web UI they governed — `brand/` is the sole design source of truth from here on (its visual-system test equivalent runs against `brand/tokens.json`). Update all `.claude/` docs and the PRD to describe the Swift architecture. Archive this plan.

**Exit:** one Swift codebase, one design system, full Apple-native macOS integration — and an `AriKit` package whose engine, store, recall, and sync layer are all Swift and multi-platform-ready. **The Mac app is now "done" in the sense that gates Phase 6.**

## Phase 6 — Ari Lite (the mobile app)

*Only starts once Phase 5 is complete (principle 4).* A standalone iOS/iPadOS app target on the finished `AriKit`, aiming for **the same feature set as the Mac app minus speaker identification**. Not a read-only viewer — it records, transcribes, and summarizes on-device, and syncs text results with the Mac through the CloudKit layer built back in Phase 1.

- **Reuse, don't rebuild.** Link `AriKit` (Models / Store / Recall / Context / Engine) directly; the shared engine already compiles for iOS. Seed the SwiftUI screens from the Mac's Phase-2 read UI + Phase-4 native screens, adapted to touch/compact layouts and themed from `brand/tokens.json`.
- **What ships:** recording (mic-first), STT (SpeechAnalyzer/WhisperKit), summarization, calendar (EventKit), recall/Ask, person profiles, series ledgers — all synced bidirectionally (text) with the Mac.
- **What's excluded / open (from the target-architecture deltas):**
  - **Speaker ID (F1)** — excluded by design; no proven on-device mobile diarization model. Revisit if FluidAudio/CoreML pyannote proves viable on iPhone/iPad or a lighter model appears. Transcripts sync from the Mac *with* speaker labels; meetings recorded on the phone have none until (if ever) opened/re-processed on a Mac.
  - **System-audio / far-side capture** — no process-tap equivalent on iOS; scope the mic-first vs call-capture question at kickoff.
  - **On-device summary model** — pick the mobile default (Gemma 4 E2B/E4B via MLX-swift, both 128K ctx, vs cloud) based on real iOS memory headroom; FoundationModels is fallback-only. On-device mobile summary is viable per the tiered strategy (see S1 / Decisions).
- **Preserve the invariants** on the new target too: recall safety shell, consent-before-record, No-Fake-State — as the ported Swift test suites, run in the iOS target.

**Exit:** a meeting recorded on either device appears (text) on the other within seconds; the mobile app is a full meeting-intelligence tool minus speaker labels. This is the multi-device product family the whole migration was for — delivered *after* a solid, finished Mac app rather than racing it.

## Subsystem migration map

*(Expanded in v2 — the v1 map missed six live subsystems and one sidecar.)*

| Today | Swift replacement | Wrapper fate | Risk | Phase |
|---|---|---|---|---|
| `cidre` system audio | Core Audio process tap (macOS 14.4+ public API) | **Vanishes** (Rust-only artifact) | Low | 3.2 |
| `cpal` mic + device_monitor | AVAudioEngine + AVAudioConverter (format-churn handling required) | **Vanishes** | Low-Med | 3.2 |
| **`ffmpeg` sidecar** (encode/mix/decode/recovery) | AVFoundation / AVAudioFile / AudioToolbox | Replaced; sidecar deleted | Med | 3.2 |
| `silero` VAD | `SpeechDetector` / small CoreML | Mostly subsumed | Low | 3.2 |
| incremental_saver crash recovery | Port to Swift (AVFoundation remux) | Native | Med | 3.2 |
| import / retranscription | Port to Swift | Native | Low | 3.2 |
| whisper.cpp / Parakeet | SpeechAnalyzer / **WhisperKit** | Replaced by framework | Med (quality — S2 genuinely open) | 3.3 |
| model-download manager | Partly dissolves (OS-managed assets) + Swift downloader | Shrinks | Low | 3.3 |
| llama.cpp (`llama-helper`) | MLX (`mlx-swift-lm`) / FoundationModels (4k ctx — short tasks only) | Replaced; sidecar deleted | Med (quality) | 3.4 (gate S1) |
| Cloud LLM providers | URLSession | Trivial | Low | 3.4 |
| **Claude CLI provider** | `Process` subprocess (not HTTP) | Native, macOS-only | Low | 3.4 |
| persons extraction / reconciliation | Port to Swift (LLM-backed, rides summary engine) | Native | Med | 3.4 |
| series detection + ledgers | Port to Swift | Native | Low | 3.4 |
| citations verify/snap (`citations.rs`) | Port to Swift + tests | Native | Med | 3.4 |
| sherpa-onnx (`diarize-helper`) | FluidAudio (CoreML pyannote, offline; weights CC-BY-4.0) | Replaced; sidecar deleted | **High** | 3.5 (gate S3) |
| `sqlx` SQLite + repositories | GRDB (candidate: Point-Free SQLiteData) + CloudKit | Native | Med | **3.1** |
| Hybrid recall + safety shell + embedders | Port to Swift, invariants as ported tests | Native | Med | **3.1** |
| **EventKit calendar sync** (`calendar/`) | EventKit direct (already native-API via objc2) | Native — **cheap early win** | Low | **2** |
| notifications / tray / **onboarding** | UserNotifications / MenuBarExtra / native flow | Native | Low | 2 |
| `apple-helper` (STT/FM probe) | Absorbed in-process | N/A | Low | 3.3 |
| `ari-notch` UI / scheduler | UI absorbed in shell / scheduler ports with engine | Split: 2 / 3.2 | Low | 2 + 3.2 |
| audio playback (asset protocol) | Bridge: `WKURLSchemeHandler` w/ byte-ranges → later native `AVPlayer` | Retired | Med | 2 → 4 |
| **MCP server (F8, committed feature)** | Build once against `AriKit` | Net-new | Med | 4 (or Swift-first earlier) |
| Next.js / React / BlockNote UI (11 routes) | SwiftUI; block editor last | Rewritten | **High (effort)** | 2 (read UI) + 4 |
| Tauri host + IPC (~140 cmds → ~90 live) | Phase-1.5 engine protocol → native calls | Retired | Med | 1.5 → 2 |
| **Existing user data + models** (26 migrations, multi-GB models) | One-shot "import existing library" migrator + verification | Net-new | Med | 2 |
| — (new) | CloudKit results/sync layer (infra, no client yet) | Net-new | Low | 1 |
| — (new) | **Ari Lite iOS/iPadOS app** (full engine minus speaker ID) | Net-new | Med (new target, platform deltas) | **6** |

## Risks & mitigations

- **STT/summary quality regression** → Phase-0 gates S1/S2 with the *committed* eval harness (P0); if a gate misses, that engine stays a Rust sidecar under the Swift shell until MLX/Apple catches up (the shell supports both via the engine protocol). S2 in particular is unproven — public data only shows SpeechAnalyzer beating Whisper-Small.
- **Diarization is the riskiest port** → scheduled last; offline-pipeline comparison only; sherpa sidecar stays callable until FluidAudio hits parity.
- **Two-writer DB corruption** → principle 3 (single owner) + store migrates first in Phase 3. Never open the SQLite file from two ORMs across processes.
- **Bridge scope creep** → the WebView is *scoped* (3 screens, ~30–40 enumerated commands), not the whole app; the native read UI ships in Phase 2 so most usage never touches the bridge.
- **Rewrite outpaced by feature work** → principle 8 WIP limits + feature-freeze scope: finish F1–F4 on Rust, freeze, build new features Swift-side. Kill any phase that hasn't shipped user-visible value in ~6 weeks and re-plan.
- **CloudKit quota / audio bloat** → sync text only (counts against the *user's* iCloud quota, not developer billing); audio stays local.
- **Data loss at cutover** → the Phase-2 import milestone with verification counts; old app-data dir left untouched until the user confirms.
- **"Rewrite that never ships"** → each phase from 2 on has a standalone user-visible Mac payoff (Phase 2 ships native shell + calendar + read UI; Phase 3 ships per-engine; Phase 4 ships native screens). Phases 1 and 1.5 are the scaffolding phases (sync store + engine extraction) — justified because they de-risk the store hub and the single riskiest cutover (host swap) and are done in known languages with tests green. **The multi-device dividend moves to the end (Phase 6) by decision** — mobile follows a finished Mac app rather than racing it.
- **Mobile scope creep / platform gaps** → the mobile app is explicitly *later* (Phase 6) and its hard deltas (no iOS system-audio tap, tighter MLX memory, no speaker-ID model) are flagged now so the shared engine is designed for them, but *resolved* only at Phase-6 kickoff — not allowed to pull scope into the Mac migration.
- **Latest-OS floor** → accepted and documented; revisit only if distribution scope (Q6) ever widens beyond personal use.

## Decisions

**Resolved during validation (2026-07-16):**
- **Apple Developer account ($99/yr)** — confirmed genuinely required for CloudKit/iCloud entitlements (not available to free accounts). Needed before Phase 1.
- **Distribution posture** — Developer ID + hardened runtime, **no App Sandbox** (sandbox would break process-tap capture and sidecar model dirs; personal-use scope doesn't need MAS). Revisit only with Q6.
- **Where the Rust engine lives during transition** — headless `ari-engine` daemon behind a versioned protocol (Phase 1.5), spawned by whichever host is current.
- **Parakeet licensing** — settled: `parakeet-tdt-0.6b-v3` is CC-BY-4.0 (attribution only). The old "separate NeMo terms must be verified" concern in product.md is stale; update it.

**Resolved 2026-07-16 (Paul):**
- **Feature freeze is *now*.** The current Rust/Tauri app works and is the frozen baseline — all of F1–F8 as they stand today ship on Rust. There is no "which features finish on Rust" list: the line is today. Going forward is Swift-first. *(Was open Q5 + Q4.)*
- **No parallel Phase 1 push; Swift *is* the single go-forward track.** Paul keeps using the working Rust product through the migration. The WIP slot is the Swift migration itself — not a Rust product still under active feature development. New features go Swift-first; the Rust app gets **reactive maintenance only**, and even a fix should be done in Swift when it reasonably can be. *(Was open Q4.)*
- **Store strategy: SQLiteData (Point-Free)**, to be confirmed load-bearing in spike S4. Rationale: it's the "lean into Apple" choice that doesn't cost us the engine. The recall/Ask differentiator is raw SQL + SQLite extensions (FTS5, sqlite-vec, BM25⊕vector RRF); SwiftData/`NSPersistentCloudKitContainer` abstracts SQLite away and would fight that. SQLiteData is real SQLite (the recall port carries straight over — the Swift mirror of today's repositories-only rule) with sync built directly on CloudKit, so multi-device works without hand-rolling conflict resolution. *(Was open Q1.)*
- **Phase 1 publisher: the Swift store owns CloudKit from day one** — no interim `cloudkit-helper` sidecar. Since Swift is the single go-forward track (not a throwaway parallel effort), there's no case for writing sync/conflict logic twice. *(Was open Q3.)*

**Resolved 2026-07-16 (Paul) — mobile app direction:**
- **Mac first, mobile after full migration.** The mobile ("lite") app is a **separate, later project that starts only once the macOS Swift migration is complete (Phase 5 done)** — built on the finished `AriKit`, not shipped early as a multi-device dividend. This reverses v2's "results-layer first" phasing: the mobile app is now Phase 6. The reuse arrow points **Mac → mobile** (the Mac's native UI seeds the mobile UI).
- **Mobile scope = full app minus speaker ID.** "Lite" means *without speaker identification (F1)*, **not** read-only. The mobile app records, transcribes, and summarizes on-device — the same feature set as the Mac — except on-device speaker diarization/re-ID, for which no proven mobile model exists yet. Revisit inclusion if one appears. (Other genuine platform gaps — no iOS system-audio process tap; tighter on-device summary-model memory — are flagged in the target architecture and resolved at Phase-6 kickoff.)
- **Sync infrastructure builds early anyway.** Even though the mobile client is last, the CloudKit-capable store + results schema land in Phase 1 (they shape the schema and are cheap under SQLiteData). Phase 1 validates the sync roundtrip *without* a mobile client so Phase 6 inherits a proven layer.

**Resolved 2026-07-16 (Paul) — summary engine:** **S1 CLOSED → GO on MLX Qwen3.5-4B (4-bit) as the on-device summary default.** The 9-meeting bake-off showed MLX-Qwen matches the shipped GGUF baseline on every quality axis (96.7% vs 96.1% citation validity, 100% vs 96.4% owner attribution, equal name-grounding), faster (27.4 s vs 33.2 s), at 2.37 GB, and the Swift-runtime spike ran it stock in `mlx-swift-lm` 3.31.4 with 100% citation validity. Paul: "if MLX Qwen3.5-4B won, I'm good to leverage that." → the `llama-helper`/llama.cpp sidecar retires at Phase 3. Gemma-4-E4B stays a **mobile-tier** candidate (citation-clean, 128K ctx, but judged weaker on substance — not the desktop default); note MLX-Qwen's 2.37 GB also fits iPhones, so it may serve both tiers (settle at Phase 6). FoundationModels remains the zero-download floor only. Cloud providers stay regardless.

**Superseded framing (kept for context) — tiered on-device strategy:** model scales to device capability — not one model everywhere. The summary engine is an abstraction with per-tier model selection: desktop (RAM headroom) runs the largest model that passes quality — MLX Qwen-4B or **Gemma 4 E4B** (128K ctx), with room to go bigger; mobile runs a mobile-grade on-device model — **Gemma 4 E2B (~1.5 GB) / E4B (~5 GB), both 128K ctx via MLX-swift** — which makes robust *on-device* mobile summarization viable (it is NOT a mobile weak point; only diarization/F1 is). FoundationModels is the zero-download floor for short content, not the default. This supersedes the earlier "FoundationModels or cloud may be the mobile default" note.

## Development tooling — Claude-Code-driven Swift

Ari is built entirely with Claude Code from the CLI (no human in Xcode); the Swift tree must be set up for that from day one. Sources reviewed 2026-07-16: [keskinonur/claude-code-ios-dev-guide](https://github.com/keskinonur/claude-code-ios-dev-guide) (793★, unlicensed — copy patterns, not text; snapshot from Jan 2026, verify tool names against current releases) and [johnrogers/claude-swift-engineering](https://github.com/johnrogers/claude-swift-engineering) (220★, MIT — safe to vendor skill content; TCA-opinionated, filter accordingly).

Adopt when the Swift tree is created (Phase 1 / 1.5):

1. **XcodeBuildMCP in `.mcp.json`** (`INCREMENTAL_BUILDS_ENABLED=true`, `XCODEBUILDMCP_DYNAMIC_TOOLS=true`) — typed build/test/clean, simulator boot/install/launch, log capture and screenshots (the agent can *see* the running app), and `swift_package_build`/`swift_package_test` for AriKit + `build_device_proj` for the macOS target. Highest-value single item.
2. **CLAUDE.md discipline ported to Swift:** root CLAUDE.md pinning Swift 6 strict concurrency, `@Observable`-MVVM (we are NOT adopting TCA unless decided otherwise), GRDB-only persistence (the Swift mirror of today's "repositories-only" rule), and min-deployment (macOS/iOS 26); plus scoped `CLAUDE.md` per AriKit feature module — same pattern as today's `frontend/` and `src-tauri/` scoped files.
3. **Hooks:** PostToolUse SwiftLint/SwiftFormat on `*.swift` edits; session-start check reporting Swift toolchain + booted-simulator state.
4. **Skills/commands translated:** `/build`, `/run-app` (build + launch the signed macOS `.app` — the analog of today's `app:local`), `/test` (`swift_package_test` + `xcodebuild test`), `/implement-feature` reading `docs/specs/`.
5. **Agent set, model-stratified** (pattern from claude-swift-engineering): a plan-only swift-architect writing `docs/plans/<feature>.md`, implementation agents, a swift-code-reviewer geared to Swift 6 concurrency migration; vendor its **GRDB and SQLite skills** (MIT) as project skills for the Store port. Skip its TCA agents.

## Sequencing summary

```
Phase 0    P0 commit eval rigs + spikes S1–S4  ── go/no-go, 2–3 weeks, engine-Swift vs sidecar
Phase 1    CloudKit sync-ready store (infra)   ── schema + sync layer early; NO mobile client yet
Phase 1.5  Extract headless ari-engine         ── command audit (~140→~90) + versioned protocol
Phase 2    Native SwiftUI shell                ── native read UI (seeds mobile later) + scoped WebView
                                                  + EventKit + notch UI + data import + TCC
Phase 3    Engine → Swift, store FIRST         ── store/recall → capture+encode → STT →
                                                  summary/persons/series → diarization
Phase 4    Remaining UI → SwiftUI (11 routes)  ── block editor last; MCP (F8) on AriKit
Phase 5    Converge & delete Rust              ── Mac app "done": one Swift package, macOS target
─────────────────────────────────────────────  ← Mac migration complete; mobile starts here
Phase 6    Ari Lite (iOS/iPadOS)               ── full engine MINUS speaker ID, on finished AriKit
```
