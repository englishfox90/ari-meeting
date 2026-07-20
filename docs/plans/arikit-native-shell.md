# AriKit — Native macOS Shell (Phase 2) + Capture Engine (Phase 3.2) — plan

> **STATUS: PLAN / not started.** Combines **Phase 2** (native SwiftUI host, the pivot —
> `plans/swift-migration-plan.md:144`) and **Phase 3 step 2** (capture + encode —
> `swift-migration-plan.md:173`, subsystem map `:236-241`). Plan-only; no code is written by
> the architect. Gated by the Opus orchestrator before any implementation slice opens.

## 0. Scope guard & WIP-limit reckoning

- **What this covers:** (a) the macOS SwiftUI app target that becomes the new host (Phase 2:
  native read UI, EventKit, notch UI absorption, menu bar/notifications, distribution posture,
  the one-shot "import existing library" milestone) and (b) the capture engine (Phase 3.2:
  Core Audio process tap + AVAudioEngine mic + AVFoundation AAC encode + VAD + incremental
  saver/crash-recovery), plus the **capture→STT seam** that joins to the 3.3 STT work being
  implemented in parallel *right now*.
- **What it does NOT cover:** the STT engine itself (Phase 3.3, in flight), summary/persons/
  series (Phase 3.4, landed), diarization (Phase 3.5), the block editor and the remaining 11-route
  UI nativization (Phase 4), CloudKit (Phase 5.5).
- **Honest framing (principle 8, `swift-migration-plan.md:45`).** The *capture engine* is a
  **port of a frozen Rust subsystem** (`frontend/src-tauri/src/audio/**` — the F-baseline audio
  path), re-implemented on the target Swift side behind the migration's dual-run discipline. The
  *native shell* is **net-new Swift host code** replacing the Tauri host — there is no Rust
  equivalent to port, so principle 2's "dual-run against the incumbent" applies to capture
  fidelity (audio equivalence), not to the shell.
- **⚠️ WIP-limit conflict — must be acknowledged, not ignored.** Principle 8 permits **one
  migration phase active**. This document opens **Phase 2 and Phase 3.2 together**, and Phase 3.3
  (STT) is already in flight. The justification, and the requested sequencing, is in §9 (Open
  decision 1): treat **capture (3.2) + STT (3.3) + a minimal recording shell (subset of Phase 2)**
  as *one indivisible "native recording vertical,"* because none of the three is independently
  shippable as user value — a native shell that cannot record is a demo, capture with nowhere to
  write is a library, STT with no audio source is untestable end-to-end. The **rest of Phase 2**
  (full native read UI, calendar, data import) and **all of Phase 4** stay sequenced *after* the
  recording vertical closes. The orchestrator must confirm this framing before slices open.

## 1. Goal & seam

**Goal.** Stand up the native macOS SwiftUI app as the new host (retiring the Tauri host), and
replace the Rust `audio/` capture subsystem with a Swift capture engine that produces the exact
PCM contract the rest of the pipeline expects — feeding the Swift STT engine (3.3) live, and
writing AAC recordings without the ffmpeg sidecar.

**Seams (`.claude/context/architecture.md`, "five seams").**
- Phase 3.2 attaches at **seam #1 — the audio pipeline PCM tap** (Q2, `open-questions.md`): the
  Rust tap point is `audio/pipeline.rs:851`, immediately after `ring_buffer.extract_window()`
  returns `(mic_window, sys_window)` and *before* `mixer.mix_window()` collapses them
  (`pipeline.rs:878`). The Swift capture engine re-creates that exact seam: **48 kHz mono f32,
  mic and system still separate**, forked non-blocking before mixing. This is the same seam F1
  (diarization, Phase 3.5) will later consume, so it is designed as a public fork point now even
  though 3.2 only feeds mixing + STT.
- Phase 2 attaches at the **host boundary**: it replaces the Tauri window/menu/tray/notifications
  and the EventKit calendar subsystem (`swift-migration-plan.md:253`, "cheap early win").

**Target-side confirmation (principle 8, `:45`).** Every artifact lands on the Swift side of an
already-cut seam: the Store/Recall/Engine seams are cut (landed), so the shell reads them
natively; capture is net-new Swift, and the frozen Rust `audio/**` is never edited. No Rust file,
no `Cargo.toml`, no `frontend/**` is touched by this plan.

**Not a re-implementation that should stop.** Capture is a port of a frozen feature, but principle
2/6 *mandate* ports land Swift-side under dual-run gates — the same sense in which Store/Recall/
Engine were "net-new on the Swift side." It proceeds.

## 2. App target structure & module boundaries

### 2.1 Where the app target lives

A new **Xcode app project `Ari/`** at the repo root (sibling to `AriKit/`, `apple-helper/`,
`ari-notch/`), consuming `AriKit` as a **local Swift package dependency** (relative path). The
Xcode project is required (not a pure SPM executable) because the app needs an `Info.plist`
(TCC usage strings), an entitlements file (hardened runtime), an asset catalog (Marginalia
colors, app icon), and code signing — none of which a bare SwiftPM executable target carries.
This mirrors today's split: `AriKit` is the agent-driven `swift build`/`swift test` package; the
app target builds via `xcodebuild` (XcodeBuildMCP `build_macos` / `/run-app`), exactly the lane
split `arikit-engine-providers.md §8` established for MLX.

```
Ari/                                  (Xcode app project — the host; xcodebuild lane)
├─ Ari.xcodeproj
├─ App/
│  ├─ AriApp.swift                    @main App; constructs AppDatabase.makeShared(at:) once
│  ├─ AppEnvironment.swift            @Observable root: repositories + engine handles injected down
│  └─ Info.plist / Ari.entitlements   TCC usage strings; hardened-runtime entitlements (§3)
├─ UI/                                 native SwiftUI, Marginalia-themed from brand/tokens.json
│  ├─ MeetingsList/ MeetingDetails/ People/ Series/   (Phase-2 native READ UI)
│  ├─ NewMeeting/ RecordingHUD/                       (the recording vertical — native)
│  └─ Notch/                          (ari-notch UI absorbed — panel only, §2.4)
├─ Capture/                           thin app-side glue only (permission prompts, wiring)
└─ Calendar/                          EventKit wrapper (§2.5)
```

### 2.2 Capture lives in a macOS-only package target, NOT in `AriKit.Engine`

The task's constraint — *capture is app-target, macOS-only, NOT shared `AriKit.Engine`* (Engine is
capture-agnostic, `swift-migration-plan.md:57`) — is honored, and improved for testability by the
**MLX-isolation pattern** (`arikit-engine-providers.md §8`): capture's **pure DSP logic** goes in a
**new macOS-only library product `AriCapture`** inside the `AriKit` package, depending on `AriKit`
(for the seam value types + `Models`), **never the reverse**. `AriKit.Engine` gains no capture
dependency and stays compilable for iOS.

Rationale (same three reasons MLX got its own target):
1. **Test-lane split (the §7 crux).** AVAudioConverter resampling, float mixing, the VAD
   segmenter, the incremental-saver state machine, and AAC encode/decode round-trips all run
   **headless in `swift test` on a Mac** (the frameworks link without a bundle; only *live device
   I/O + TCC* needs the signed bundle). Isolating them in `AriCapture` gives them a real
   `swift_package_test` home. The live-device classes are `#if os(macOS)` and bundle-gated.
2. **Engine stays capture-agnostic & iOS-buildable.** iOS capture is mic-only and different
   (`swift-migration-plan.md:77`); keeping capture out of Engine means the Phase-6 iOS target
   reuses Engine unchanged and supplies its own mic-only capture.
3. **Clean protocol isolation.** `AriCapture` only needs the seam types (`PCMWindow`,
   `CaptureConfig`) which live in `AriKit`; a downstream target conforming to upstream types is
   idiomatic SPM.

> **Open decision (§9-2):** `AriCapture` as a package product vs. capture-in-app-target folder.
> Recommendation: **package product**, for the headless DSP test lane. The live-device classes
> stay `#if os(macOS)` regardless.

```
AriCapture/                           (macOS-only library product in AriKit/Package.swift; #if os(macOS))
├─ SystemAudioTap.swift               Core Audio process tap → aggregate device → IOProc (§4.1) — device-gated
├─ MicrophoneCapture.swift            AVAudioEngine + AVAudioConverter (§4.2) — device-gated
├─ CaptureCoordinator.swift           lifecycle, ring-buffer windowing, the PCM fork seam (§4.3)
├─ AudioMixer.swift                   48 kHz mono float mix (pure — headless-testable)
├─ Resampler.swift                    AVAudioConverter wrapper to 48 kHz mono (pure-ish — headless)
├─ SpeechVAD.swift                    SpeechDetector / CoreML-silero segmenter (§4.5)
├─ AACRecorder.swift                  AVAudioFile/AVAssetWriter AAC-LC 192k (§4.4) — headless
└─ IncrementalSaver.swift            30 s checkpoint + crash-recovery remux (§4.6) — headless
```

### 2.3 Public seam types (in `AriKit`, so both `AriCapture` and `Engine` see them)

```swift
/// One window of captured PCM at the fork point (← audio/recording_state.rs AudioChunk).
/// 48 kHz mono f32, mic and system still SEPARATE. Sendable value type — crosses the
/// non-blocking fork to STT / (later) diarization without shared mutable state.
public struct PCMWindow: Sendable {
    public var samples: [Float]        // mono, [-1, 1]
    public var sampleRate: Double      // 48_000 at the fork
    public var source: CaptureSource   // .microphone | .system  (← DeviceType)
    public var hostTime: Double        // seconds from recording start (← AudioChunk.timestamp)
    public var windowID: UInt64
}

public enum CaptureSource: Sendable { case microphone, system, mixed }
```

`PCMWindow` is the single contract the capture→STT seam (§5) is built around.

### 2.4 Notch UI absorption (Phase 2, panel only)

`ari-notch/` sidecar's **UI panel** (recording HUD + upcoming-meeting alert, DynamicNotchKit MIT)
is absorbed as a native SwiftUI window in `Ari/UI/Notch/`. Its **scheduler/state brain** stays in
Rust `notch/bridge.rs` and ports later with the engine (`swift-migration-plan.md:152, :256`);
Phase 2 absorbs the panel, not the brain — the panel is driven by the native recording state and
the live level published from `CaptureCoordinator` (the Swift analog of `audio/live_level.rs`,
`pipeline.rs:817`).

### 2.5 EventKit calendar (Phase 2, cheap early win)

`calendar/` ports into `Ari/Calendar/` as a direct EventKit wrapper — it is already native-API
code (objc2 in Rust), the most TCC-sensitive subsystem, and benefits most from a real bundle
identity (`swift-migration-plan.md:153`; the `build-and-run.md` TCC reality: Calendar can *never*
be granted under a bare binary). It is scheduled in the *later* Phase-2 tranche (after the
recording vertical), and it is what F4→F1 (diarization speaker-count hint, `swift-migration-plan.md:176`)
and series detection (`arikit-engine-providers.md` Slice I) will consume.

## 3. Distribution posture & TCC (Q6)

Pinned per `open-questions.md` Q6 (RESOLVED 2026-07-16) and `swift-migration-plan.md:154, :282`:

- **Developer ID + hardened runtime, NO App Sandbox.** Sandboxing would break the Core Audio
  process tap and the sidecar/model directories; personal-use scope needs no MAS/notarization.
- **No paid Apple Developer account for Phase 2–5.** The full local Mac app builds/runs on a
  **self-signed identity** exactly like the Tauri app does today — reuse the existing
  **`Ari Dev Signing`** cert (`build-and-run.md`) or mint a fresh self-signed one. The paid account
  is the CloudKit entitlement key, needed only at Phase 5.5.
- **Hardened-runtime entitlements** required for capture:
  `com.apple.security.device.audio-input` (microphone) and `com.apple.security.device.camera`
  is *not* needed. `NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription`, and
  `NSCalendarsFullAccessUsageDescription` go in `Info.plist` (the audio-capture key must be
  entered manually — it is not in Xcode's dropdown; confirmed via AudioCap/Apple docs, Sources).
  The Rust code confirms the tap-permission model: the prompt fires automatically on first
  `AudioHardwareCreateProcessTap` and denial yields silence, not an error (`audio/permissions.rs:18-24`).
- **One-time TCC re-grant.** A new code identity means Mic / Screen Recording (audio-capture) /
  Calendar grants reset once — expected, documented, done (`swift-migration-plan.md:154`).
  Provide a `/run-app`-equivalent (`/run-app` per tooling §, `swift-conventions.md`) that builds +
  signs + `open`s the `.app` with the stable identity so grants persist across rebuilds — the
  direct analog of today's `pnpm run app:local` (`build-and-run.md`).
- **Bundle identifier decision (§9-6):** keep `com.meetily.ai` to inherit the existing app-data
  dir + TCC grants, or move to `com.arivo.ari` and re-grant + re-point the importer. The Store's
  `LegacyDatabaseImporter` reads the source dir read-only regardless, so a new bundle id is safe
  for data (import is a copy), but costs a TCC re-grant either way (new code identity already
  forces one). Recommendation: **new id `com.arivo.ari`** — the rebrand was deferred only to avoid
  orphaning the *live Tauri app's* data dir (`open-questions.md` tracked follow-ups); a fresh Swift
  app importing *from* the old dir has no such constraint.

## 4. Capture engine (Phase 3.2) — the meat

Behavior-parity target: the frozen Rust `audio/` path. Format facts to preserve
(`coding-conventions.md` audio facts; `pipeline.rs`): consistent **48 kHz** internal rate, mic
16→48 kHz resample, system 48 kHz passthrough, 48 kHz mono AAC output; VAD reduces STT load ~70 %.

### 4.1 System audio — Core Audio process tap (`SystemAudioTap`, `#if os(macOS)`)

Direct public-API port of `audio/capture/core_audio.rs` (the cidre wrapper "vanishes",
`swift-migration-plan.md:236`). Verified API surface (Apple docs + AudioCap sample, Sources):
- `CATapDescription` — **mono global tap excluding no processes** (byte-for-byte the Rust choice,
  `core_audio.rs:91` `with_mono_global_tap_excluding_processes(&[])`). This captures **ONE mixed
  mono system stream** — Q3's confirmed reality (`open-questions.md`): individual remote
  participants are *not* separable from this stream; that is F1's known ceiling, not a capture bug.
- `AudioHardwareCreateProcessTap(tapDescription)` → tap `AudioObjectID`.
- `AudioHardwareCreateAggregateDevice(dict)` with `kAudioAggregateDeviceIsPrivateKey = true`,
  `kAudioAggregateDeviceTapAutoStartKey = true`, and the tap UID in `kAudioAggregateDeviceTapListKey`
  — and **crucially NOT a sub-device list** (the Rust code's hard-won fix, `core_audio.rs:120-133`:
  including both the output device *and* its tap double-captures → echo. Port this exactly.)
- `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` — the IOProc block delivers float
  samples; publish into a lock-free ring to the coordinator (mirrors the Rust `HeapRb` +
  `WakerState`, `core_audio.rs:34-41`).
- Sample-rate churn: the tap ASBD sample rate can change (default-output device switch); track it
  (`core_audio.rs` `current_sample_rate: AtomicU32`) and re-assert the resample target.
- Permission: the prompt fires automatically on tap creation; denial → silence. Surface an honest
  **No-Fake-State "System audio unavailable"** readiness state (never a fake green), the Swift
  analog of the fix noted in memory `recording-start-tcc-and-readiness`.

### 4.2 Microphone — `MicrophoneCapture` (AVAudioEngine + AVAudioConverter)

Replaces `cpal` (`swift-migration-plan.md:237`; note `audio/capture/microphone.rs` is a Rust
placeholder — live mic capture is cpal via `audio/stream.rs`). Budget the documented gotchas
(`swift-migration-plan.md:173`, subsystem map risk "Low-Med"):
- `inputNode.installTap(onBus:0, bufferSize:, format:)` **must** use
  `inputNode.outputFormat(forBus:0)` (the hardware format) or it crashes — do not force a format.
- Resample to **48 kHz mono f32** via `AVAudioConverter` (`Resampler.swift`, pure-testable).
- **Device churn** — the AirPods 16/24 kHz problem. Observe
  `AVAudioEngineConfigurationChange` (posted on hardware-format change / device switch); on it,
  stop, re-read the hardware format, rebuild the converter, restart — the same disconnect/
  reconnect + Bluetooth-heuristic handling `audio/device_monitor.rs:38-52` does today
  (`is_bluetooth` name heuristic). The Bluetooth resampling distortion itself is a macOS artifact,
  not our bug (`coding-conventions.md`) — do not try to "fix" it.

### 4.3 `CaptureCoordinator` — windowing, mixing, and the PCM fork seam

The Swift analog of `AudioPipeline::run()` (`pipeline.rs`). It:
1. feeds mic (post-resample) + system samples into a ring buffer keyed by `CaptureSource`
   (← `ring_buffer.add_samples`, `pipeline.rs:847`);
2. extracts fixed ~600 ms windows when both streams have data (← `extract_window()`,
   `pipeline.rs:851`);
3. **forks the SEPARATE mic + system windows** as `PCMWindow` values to any registered consumer
   (STT §5; later diarization F1) **before** mixing — the exact Q2 seam, non-blocking
   fire-and-forget (← `recording_sender_for_mic/_system`, `pipeline.rs:856-875`). **Never do
   inference on this loop** (Q2 hard rule);
4. mixes to a single 48 kHz mono window (`AudioMixer.swift`, pure — no aggressive ducking,
   ← `mixer.mix_window`, `pipeline.rs:878`; mic already EBU-R128-normalized so no post-gain,
   `pipeline.rs:880-884`);
5. publishes a peak-hold live level for the notch HUD (← `live_level::publish`,
   `pipeline.rs:810-818`) — lock-free, never blocks;
6. hands mixed windows to VAD → STT (§5) and to the incremental saver (§4.6).

### 4.4 Encode — `AACRecorder` (AVFoundation, replacing the ffmpeg sidecar)

The ffmpeg sidecar has **four duties** — all four must be replaced before it is deleted
(`swift-migration-plan.md:238`, subsystem map "Med" risk):
- **Encode:** Rust does f32le → AAC-LC 192 kbps, `.mp4`, `+faststart` (`audio/encode.rs:38-57`).
  Swift: `AVAudioFile(forWriting:settings:)` or `AVAssetWriter` with
  `AVFormatIDKey = kAudioFormatMPEG4AAC`, `AVEncoderBitRateKey = 192_000`, 48 kHz mono, `.m4a`/`.mp4`.
- **Mix:** now done in-Swift (`AudioMixer`, §4.3) — ffmpeg no longer mixes.
- **Decode:** for import + retranscription, `AVAudioFile(forReading:)` → PCM (replaces
  `audio/decoder.rs`/ffmpeg decode).
- **Crash-recovery remux:** concatenate the 30 s checkpoint segments into the final file — Swift:
  `AVMutableComposition` + `AVAssetExportSession` (or sequential `AVAudioFile` append). This is the
  `incremental_saver` merge step (§4.6).

### 4.5 VAD — `SpeechVAD`

Port `audio/vad.rs` (silero, 16 kHz hard requirement, tuned thresholds
0.50/0.35 + redemption for continuous speech, `vad.rs:31-45`, min-segment 800 samples/50 ms,
`pipeline.rs:892`). Two candidate implementations (§9-3): **(a)** Apple `SpeechDetector` (Speech
framework, the module SpeechAnalyzer already exposes — cheapest, and STT 3.3 may already run it);
**(b)** a small CoreML silero if `SpeechDetector`'s segmentation doesn't match the tuned recipe.
Downsample the mixed 48 kHz window to 16 kHz for VAD (as today). The segmenter's logic
(in/out-of-speech state, redemption, min-length) is pure and **headless-testable** on fixture PCM.
No-Fake-State: an empty/too-short segment returns honest empty, never invented (mirrors
`apple_provider.rs:12-15` `MIN_SAMPLES`).

### 4.6 Incremental saver / crash recovery — `IncrementalSaver`

Port `audio/incremental_saver.rs`: 30 s checkpoint interval (1,440,000 samples @ 48 kHz,
`incremental_saver.rs:21`), per-track stems (`audio`/`mic`/`system`) sharing one `.checkpoints/`
dir (`incremental_saver.rs:26-32`), write each checkpoint as an AAC segment, then remux on
finalize (§4.4). On launch, detect an orphaned `.checkpoints/` (crash) and offer recovery. State
machine (checkpoint counting, buffer flush, merge order) is pure and **headless-testable**.

### 4.7 Consent-before-record (invariant)

Recording is **always explicitly initiated + consented — never silent auto-record**
(`product.md`; principle 6). The native flow: user action → TCC prompts (mic + audio-capture) →
recording. The calendar-triggered path (F5) is a *prompt-to-record notification*, never an
auto-start (`product.md`, memory `external-stop-must-emit-complete`). Encode this as a test that
no code path starts capture without an explicit `startRecording()` call originating from user
intent.

## 5. The capture → STT seam (join to Phase 3.3, in flight)

**This is the coordination centerpiece** — 3.2 (this plan) produces audio; 3.3 (being built now)
consumes it. Design the contract so they meet cleanly and neither blocks the other:

- **Capture emits `AsyncStream<PCMWindow>`** (mixed, 48 kHz mono) via `CaptureCoordinator`, plus a
  separate `AsyncStream<PCMWindow>` of the *pre-mix* mic/system fork (for F1 later). The stream
  uses **bounded buffering with drop-oldest backpressure** (`AsyncStream.Continuation`
  `.bufferingNewest(n)`) so a slow consumer can never stall the audio hot path (Q2's hard rule;
  the Rust loop has a 50 ms recv timeout and dropping is preferred to blocking).
- **STT (3.3) adapts `PCMWindow` → `AnalyzerInput`.** Apple's live path is
  `SpeechAnalyzer(modules: [transcriber])` + `analyzer.analyzeSequence(inputs)` where `inputs` is
  an `AsyncSequence<AnalyzerInput>` wrapping `AVAudioPCMBuffer`
  (`swift-migration-plan.md:174`, the `RecognizingSpeechInLiveAudio` sample). The adapter — a tiny
  `PCMWindow → AVAudioPCMBuffer → AnalyzerInput` map — is the **join point**. **Ownership decision
  (§9-4):** the adapter belongs to the **STT side (Engine, 3.3)**, so `AriCapture` stays
  transcription-agnostic and only ever speaks `PCMWindow`; Engine converts. This keeps Engine
  capture-agnostic in the *type* direction (it depends on `AriKit.PCMWindow`, a plain value type,
  not on `AriCapture`).
- **Contract to hand the 3.3 implementer NOW:** (i) element type `PCMWindow` (§2.3); (ii) 48 kHz
  mono f32, mono channel; (iii) `hostTime` is seconds-from-start for transcript time-alignment
  (the Rust "timing is free" property, `open-questions.md` Q4 — VAD segment PCM == STT PCM ==
  transcript time range); (iv) backpressure is drop-oldest, so STT must tolerate gaps honestly
  (No-Fake-State — a dropped window is silence, not invented text). Publishing this type + these
  four guarantees is the single most time-sensitive output of this plan.
- **VAD placement:** VAD (§4.5) sits *between* capture and STT (STT transcribes speech segments,
  not raw windows — the ~70 % load reduction). Whether SpeechAnalyzer's own `SpeechDetector`
  subsumes our VAD (so capture forwards raw windows) or we keep a pre-STT VAD is §9-3 — flag it to
  the 3.3 implementer because it changes what capture must emit.

## 6. Persistence & data continuity

### 6.1 Single-DB-owner (principle 3) reasserted

Capture writes **no DB rows itself** — it produces audio files + PCM. Recording metadata
(meeting row, audio file path, transcript rows) is written through `AriKit.Store`'s repositories
only (`AppDatabase`, the single owner, `arikit-store.md §2.2`). The app target constructs one
`AppDatabase.makeShared(at:)` at launch and injects repositories into view models
(`arikit-store.md §2.2` — "Store never reads FileManager paths; the app resolves them"). No raw
SQLite handle, no second connection, ever.

### 6.2 "Import existing library" milestone (Phase 2)

Adopt the live app-data dir `~/Library/Application Support/com.meetily.ai`
(`swift-migration-plan.md:155`):
- **Database:** the Store's **`LegacyDatabaseImporter` already exists and passed a data-fidelity
  gate** (`arikit-store.md §0` — read-only, idempotent, honest `ImportReport` reconciliation,
  `meeting_notes` preserved). Phase 2 *drives* it from the app on first launch; it is not rebuilt.
- **Audio files + checkpoints:** the meeting folders + `audio.mp4` + `.checkpoints/` are
  file-by-reference or copied into the new app's data dir (audio-by-reference is the Store's model,
  `arikit-store.md §0`). Verify each imported meeting's audio path resolves post-import.
- **Downloaded models:** largely **dissolve** — SpeechAnalyzer assets are OS-managed
  (`swift-migration-plan.md:243`), llama-helper GGUF retires for MLX (3.4), Parakeet ONNX is
  replaced by SpeechAnalyzer, embedder default is Apple `NLEmbedding` (no download, memory
  `ask-embedder-pluggable`). So model-dir import is mostly a no-op; only keep what a still-live
  path needs.
- **Settings / API keys:** audit DB vs Keychain (`swift-migration-plan.md:155`). Keychain items are
  tied to the signing identity/team and **can be orphaned** by the identity change — surface any
  un-migratable key as an honest "re-enter your API key" prompt, never a silent empty (No-Fake-State).
- **Post-import verification counts** (honest reconciliation): meetings/transcripts/summaries/
  notes counted source-vs-dest, surfaced in the `ImportReport` UI. Leave the old dir untouched
  until the user confirms (`swift-migration-plan.md:273`, data-loss mitigation).

## 7. THE crux — test strategy (the honesty item)

Capture is deeply TCC-gated (mic + audio-capture) and **cannot be verified from `swift test`** —
a real signed `.app` + granted permissions are required. State the lanes explicitly, mirroring
`arikit-engine-providers.md §8`'s MLX lane split:

### Lane 1 — Headless `swift_package_test` (no bundle, no TCC, agent-runnable)
Everything pure/DSP in `AriCapture`, tested against fixture PCM/audio files:
- `ResamplerTests` — AVAudioConverter 16→48 / 24→48 / 48→48 kHz mono correctness on fixture buffers
  (sample-count, no clipping, mono downmix).
- `AudioMixerTests` — two-window mix = expected sum, no post-gain, silence-system decays cleanly.
- `SpeechVADTests` — segmentation on fixture speech/silence PCM: min-length gate (800 samples),
  redemption across natural pauses, honest-empty on too-short (parity with the `vad.rs` recipe).
- `IncrementalSaverTests` — checkpoint counting at 30 s boundaries, per-track stem naming
  (`audio`/`mic`/`system`), orphaned-checkpoint detection, **remux concatenation** = one file whose
  duration == sum of segments (fixture `.m4a` segments; AVFoundation works headless).
- `AACRecorderRoundTripTests` — encode fixture PCM → `.m4a` → decode → PCM within tolerance;
  AAC-LC 192 k / 48 kHz mono settings assertion.
- `ConsentInvariantTests` — no capture starts without an explicit `startRecording()` (consent-
  before-record; static wiring assertion).
- `PCMWindowContractTests` — `PCMWindow` is `Sendable`; the fork stream is drop-oldest bounded
  (a slow consumer cannot stall the producer — modelled with a fake slow consumer).

### Lane 2 — Signed `.app` bundle + human grant (NOT CI-green; a documented manual QA checklist)
The live device I/O — the honest admission that these cannot be automated in `swift test`:
- **Mic capture** — `/run-app`, grant Microphone, record 30 s, confirm a valid `.m4a` with speech.
- **System-audio tap** — grant Audio-Capture, play known system audio, confirm it appears in the
  recording (and that **no echo** — the sub-device-list fix, §4.1).
- **Device churn** — start recording on built-in mic, connect AirPods mid-recording (16/24 kHz),
  confirm recording continues without crash and re-converts (the `AVAudioEngineConfigurationChange`
  path, §4.2).
- **TCC denial → No-Fake-State** — deny audio-capture, confirm the UI shows an honest "System
  audio unavailable," never a fake ready/green.
- **Crash recovery** — kill the app mid-recording, relaunch, confirm the orphaned `.checkpoints/`
  is detected and remuxed into a recoverable file.
- **End-to-end recording vertical** — record → PCM → STT (3.3) → transcript rows persisted → audio
  playable. This is the dual-run bar: compare a Swift recording against a Rust-app recording of the
  same source for audio equivalence (level, no echo, duration) — the principle-2 "meet or beat the
  incumbent" check, run manually since it needs live devices.

Each Lane-2 item is a **checklist step in the slice's acceptance criteria**, executed in the signed
app via XcodeBuildMCP (`build_macos` + `launch` + log/screenshot capture, so the agent can *see* the
running app, `swift-conventions.md`) with a human granting TCC once. **No Phase-3.2 slice is "done"
on Lane-1 green alone** — the device-I/O slices require the Lane-2 checklist signed off. This is the
honest bar; pretending capture is CI-gated would be No-Fake-State applied to our own process.

### Spike gates
No new spike. The relevant prior gates are **S2 (STT, GO-with-caveats)** — the seam this feeds —
and the S2 caveat worth honoring here: a true 60–80 min single-file recording was never exercised
(`swift-migration-plan.md:94`), so the Lane-2 checklist must include **one long (>60 min) recording**
to validate no-chunking + the 30 s checkpoint/remux path at scale before the vertical closes.

## 8. Invariants preserved (principle 6)

- **Consent-before-record** — §4.7; `ConsentInvariantTests` (Lane 1) + manual TCC-flow (Lane 2).
  Never silent auto-record; F5 calendar path is prompt-only.
- **No-Fake-State** (design-system rule + backend recall invariant) — honest readiness/permission
  states (System-audio-unavailable on tap denial; re-enter-key on orphaned Keychain; honest
  `ImportReport` counts; dropped-window == silence not invented text; VAD honest-empty). Never a
  fabricated meter, progress, or green state.
- **Loopback-only / bounded-context / never-invents-citations** — *not touched by capture*; they
  live in Recall/Engine (landed) and survive as the already-ported Swift test suites. Noted for
  completeness; the shell reads them unchanged.
- **Single-DB-owner** (principle 3) — §6.1; capture writes no rows, metadata goes through
  `AppDatabase` repositories only.

## 9. Open decisions for the human

1. **WIP-limit framing (the big one).** Confirm treating **capture (3.2) + STT (3.3, in flight) +
   a minimal recording shell** as one indivisible "native recording vertical," with the rest of
   Phase 2 (full read UI, calendar, import) and all of Phase 4 sequenced after. Alternative: hold
   3.2 until 3.3 lands (serializes, but respects one-phase-at-a-time literally). *Recommendation:
   the vertical* — none of the three is independently shippable, and the seam (§5) is cheaper to
   design once, together.
2. **`AriCapture` as a package product vs. app-target folder** (§2.2). *Recommendation: package
   product* for the headless DSP test lane; live-device classes stay `#if os(macOS)`.
3. **VAD: Apple `SpeechDetector` vs. CoreML silero, and where it sits relative to STT** (§4.5, §5).
   Changes what capture emits to 3.3 — must be settled *with* the 3.3 implementer. *Recommendation:
   try `SpeechDetector` first (already in the SpeechAnalyzer module set); keep the tuned-silero
   recipe as the fallback if segmentation regresses.*
4. **Capture→STT adapter ownership** (§5). *Recommendation: the STT/Engine side owns the
   `PCMWindow → AnalyzerInput` adapter; `AriCapture` stays transcription-agnostic.*
5. **Native-first vs. scoped-WebView** — see the dedicated recommendation below (§10). *Needs an
   explicit yes/no before Phase-2 UI slices open.*
6. **Bundle identifier** — keep `com.meetily.ai` or move to `com.arivo.ari` (§3). *Recommendation:
   `com.arivo.ari`* (a fresh Swift app importing from the old dir has no orphaning constraint).
7. **Long-recording validation** — confirm the Lane-2 checklist must include one >60 min recording
   before the vertical closes (§7, S2 caveat).

## 10. Native-first vs. scoped-WebView — RECOMMENDATION

The v2 plan (`swift-migration-plan.md:148-151`) hosted the *hard* screens (block editor, settings,
new-meeting/recording) in a scoped WKWebView bridging ~30–40 commands + an event push channel +
a byte-range `WKURLSchemeHandler` for audio scrubbing. **Reconsidered here, the recommendation is
(a) go fully native from the start, with the block editor as the single deferred holdout — no
WebView bridge.**

**Why native-first wins now:**
- **The premise that justified the bridge is gone.** The bridge existed to *preserve the working
  React screens while the strangler ran*. But the user is **not using the Rust/React app anymore**
  (frozen baseline; go-forward is Swift-only, `swift-conventions.md`). Preserving React screens
  buys nothing if no one runs them.
- **The bridge is 100 % throwaway *and* a whole new subsystem.** It is not free — it is a
  `WKScriptMessageHandler` invoke-adapter, an `evaluateJavaScript` event-push channel, *and* a
  byte-range URL-scheme handler (to replace `convertFileSrc`, memory `meeting-open-perf`) — built
  only to be deleted in Phase 4. That is real engineering effort spent on code with a scheduled
  death date.
- **The recording vertical is native regardless.** New-meeting / recording / HUD (§2, §4) are
  built native in 3.2 — the very screens the bridge would have hosted. Read UI is native day one.
  Settings is a plain form — trivially native. So the bridge's only real tenant would be the block
  editor.
- **Audio playback goes native immediately** — `AVPlayer` (§ Phase 4 note, `swift-migration-plan.md:191`),
  which *eliminates the byte-range URL-scheme handler entirely* — the single most fiddly bridge
  piece. No reason to build it.

**The block editor — the one genuinely hard screen** (`swift-migration-plan.md:33`, the correction:
`TextEditor`+`AttributedString` on macOS 26 covers *rich text*; what has no native equivalent is
**BlockNote-style block editing** — drag handles, slash menus, and the ProseMirror `@ref` /
`@ref(MM:SS)` badge decorations, memory `reference-timestamp-badges`). Handling for Phase 2/3.2:
- **Meeting notes / summary render + light edit natively now** via `TextEditor` bound to
  `AttributedString` — read, select, basic formatting, and **read-only `@ref` badges** rendered as
  `AttributedString` runs with a tap action to seek `AVPlayer`. This covers the recording vertical
  and the read UI.
- **The full block-editing experience (drag/slash/interactive badges) is deferred to Phase 4**,
  where it gets a **native rebuild on the `AttributedString` foundation** — *or*, only if a native
  rebuild proves genuinely too costly, that *one panel* may get a narrowly-scoped WebView **decided
  at Phase 4, on evidence, not pre-committed now.** Deferring the *decision* (not building a bridge
  speculatively) is the cheap, reversible choice.

**Net:** build no WebView bridge in Phase 2. Native shell hosts everything; the block editor's
advanced editing is the sole deferred item, and whether it is ever a WebView is a Phase-4 call.
This deletes an entire throwaway subsystem (invoke-adapter + event-push + byte-range handler) from
the plan.

## 11. Risks & dependency-ordered sequencing

Each slice independently testable (Lane 1 headless where possible; Lane 2 signed-bundle checklist
for device I/O). The recording vertical (§9-1) is the spine.

**S0 — App skeleton + signing + data dir (Phase 2 foundation).** `Ari.xcodeproj`, `@main` app,
`AppDatabase.makeShared` wired, self-signed `Ari Dev Signing`, hardened-runtime entitlements +
Info.plist TCC strings, `/run-app` command. *Accept:* app launches signed, opens the Store DB,
Lane-2 shows a window. No capture yet.

**S1 — `AriCapture` pure DSP core (headless).** `PCMWindow` seam type (in `AriKit`), `Resampler`,
`AudioMixer`, `AACRecorder`, `IncrementalSaver` state machine, `SpeechVAD` logic. *Accept:* Lane-1
suite green (§7). **Unblocks the 3.3 seam:** publish `PCMWindow` + the four §5 guarantees to the
STT implementer the moment this lands.

**S2 — `MicrophoneCapture` (device-gated).** AVAudioEngine + converter + churn handling. *Accept:*
Lane-2 mic checklist (record, AirPods churn, denial→honest state).

**S3 — `SystemAudioTap` (device-gated).** Process tap → aggregate device → IOProc; the no-echo
sub-device-list fix. *Accept:* Lane-2 system-audio checklist (capture, no echo, denial→No-Fake-State).

**S4 — `CaptureCoordinator` (windowing + fork + mix + live level + save).** Wires S1–S3; the Q2
PCM fork seam; incremental save + finalize/remux. *Accept:* Lane-2 end-to-end recording produces a
valid `.m4a`; live level drives the notch HUD; crash-recovery remux works.

**S5 — capture→STT join (with 3.3).** Adapter (Engine side) consumes `PCMWindow`; end-to-end
record→transcript. *Accept:* Lane-2 full vertical + the >60 min long-recording check (§7, S2 caveat);
dual-run audio-equivalence vs. a Rust-app recording.

**S6 — native read UI (Phase 2, after the vertical).** Meetings list / details / people / series,
Marginalia-themed, driven from AriKit repositories. Native `AVPlayer` playback. *Accept:*
visual-system parity (`MarginaliaTokenParityTests` analog for the app), read flows work on imported
data.

**S7 — EventKit calendar + notch panel + notifications/menu bar (Phase 2 tail).** *Accept:* Lane-2
Calendar grant works under the signed bundle (impossible under a bare binary, `build-and-run.md`).

**S8 — "import existing library" milestone.** Drive `LegacyDatabaseImporter` from the app + audio-
file adoption + verification counts + honest key re-prompt. *Accept:* imported meeting counts
reconcile; old dir untouched; a legacy meeting opens with audio + transcript + notes.

**Risks:**
- **Capture cannot be CI-gated** (§7) — mitigated by the Lane-1/Lane-2 split + explicit manual
  checklists; the honest bar is stated, not hidden.
- **AVAudioEngine device churn** (AirPods) — the highest capture-fidelity risk; S2 budgets the
  `AVAudioEngineConfigurationChange` rebuild explicitly.
- **Process-tap echo / duplicate capture** — the Rust code's hard-won sub-device-list fix
  (`core_audio.rs:120`) is ported verbatim in S3; the Lane-2 no-echo check gates it.
- **WIP-limit / three phases open** (§0, §9-1) — mitigated by the vertical framing; the orchestrator
  confirms before slices open. If not confirmed, fall back to serializing 3.2 behind 3.3.
- **STT seam churn** — mitigated by publishing `PCMWindow` + the four guarantees at S1 (before the
  3.3 implementer needs them), so the contract is fixed early, not renegotiated late.
- **ffmpeg feature-parity gaps** (obscure container/remux edge cases) — mitigated by the AAC round-
  trip + remux Lane-1 tests and the long-recording Lane-2 check.

## Sources

- Apple, *Capturing system audio with Core Audio taps* (macOS 14.4+, `CATapDescription` /
  `AudioHardwareCreateProcessTap` / `AudioHardwareCreateAggregateDevice` /
  `AudioDeviceCreateIOProcIDWithBlock` / `NSAudioCaptureUsageDescription`).
- insidegui/AudioCap — sample code for system-audio recording on macOS 14.4+ (API surface + the
  manual `NSAudioCaptureUsageDescription` Info.plist key).
- Rust incumbent read for behavior parity: `audio/capture/core_audio.rs`, `audio/pipeline.rs`,
  `audio/encode.rs`, `audio/incremental_saver.rs`, `audio/device_monitor.rs`, `audio/vad.rs`,
  `audio/permissions.rs`, `audio/recording_manager.rs`, `audio/transcription/apple_provider.rs`.
