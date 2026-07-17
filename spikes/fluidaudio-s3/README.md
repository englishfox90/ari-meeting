# fluidaudio-s3 — offline diarization spike

Throwaway Swift CLI spike (NOT part of AriKit/product code) proving out
**FluidAudio**'s offline (pyannote community-1) CoreML speaker-diarization
pipeline on real meeting audio, for the Swift-migration S3 diarization eval
(see `plans/swift-migration-plan.md`). Emits standard RTTM so the existing
Python DER rig at `tools/diarization-sweep/` can score it exactly like the
app's shipped sherpa-onnx `diarize-helper` output.

This package is intentionally isolated from `tools/diarization-sweep/` —
nothing under that directory was modified. It only *produces* an RTTM file
that a human/agent can feed into that rig's existing scoring scripts.

## What it proves

FluidAudio's **offline/complete** pipeline (`OfflineDiarizerManager`), not the
streaming `LSEENDDiarizer` — streaming DER is known to be far worse and is
out of scope for S3.

## Package / API notes (verified against the real source, 2026-07-17)

- **Version pinned:** `FluidAudio` `0.15.5` (exact), latest tag at spike time.
  `Package.swift`: `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")`.
- **Deployment:** FluidAudio itself requires macOS 14+ / iOS 17+ (its own
  `Package.swift`). This spike's own package platform is pinned to
  `.macOS(.v26)` per house convention (`swift-tools-version: 6.2`, required
  for the `.v26` platform enum case) — that's *our* floor, not a FluidAudio
  requirement.
- **Real API surface used** (confirmed by reading
  `Sources/FluidAudio/Diarizer/Offline/Core/*.swift` in the cloned repo —
  the README's "legacy" `DiarizerManager.performCompleteDiarization` snippet
  is the *older*, non-offline pipeline; the offline pipeline used here is a
  distinct, newer class):
  - `OfflineDiarizerConfig` — `.default` static, mutable `clusteringThreshold: Double` computed property (backs `clustering.threshold`, must be in `(0, sqrt(2)]`).
  - `OfflineDiarizerManager(config:)` — `public init(config: OfflineDiarizerConfig = .default)`.
  - `manager.prepareModels()` — `async throws`, downloads + compiles the CoreML bundle on first run (idempotent; skips if already loaded).
  - `manager.process(audio: [Float], progressCallback: ((Int, Int) -> Void)?)` — `async throws -> DiarizationResult`. Also has a `process(_ url: URL, ...)` overload that streams a file directly (not used here — we hand-parse the WAV instead, see below).
  - `DiarizationResult.segments: [TimedSpeakerSegment]` — each with `speakerId: String`, `startTimeSeconds: Float`, `endTimeSeconds: Float`, `durationSeconds` (computed), `embedding: [Float]`, `qualityScore: Float`.
  - `OfflineDiarizerModels.defaultModelsDirectory()` — the CoreML model cache path (`static func`, no instance needed).
  - Speaker IDs are stamped as `"S1"`, `"S2"`, ... (1-indexed cluster labels), per `OfflineDiarizerManager.buildPublicChunkEmbeddings`'s doc comment (`"S\(cluster + 1)"`).
- **No WAV/audio-conversion helper used from FluidAudio.** The README shows an
  `AudioConverter().resampleAudioFile(path:)` helper, but this spike instead
  hand-parses the WAV file itself (see `loadWAV16kMono` in `main.swift`) so
  the CLI can **validate and hard-fail** if the input isn't already 16 kHz
  mono, rather than silently resampling — the `tools/diarization-sweep/` rig
  always pre-decodes with ffmpeg first, so requiring 16 kHz mono is the
  correct contract for this spike.

## Build

```bash
cd spikes/fluidaudio-s3
swift build -c release
```

First build resolves and fetches the `FluidAudio` package (pulls in its
`FastClusterWrapper`/`MachTaskSelfWrapper` C targets and a prebuilt
`NemoTextProcessing` xcframework binary target used by FluidAudio's TTS/ASR
code — unused by diarization but part of the same library product, so it's
fetched regardless). No Metal shader compilation step (unlike the MLX S1
spike) — this is pure CoreML, compiled by `MLModel`/`coremlc` at model-load
time inside `prepareModels()`, not at Swift build time.

Binary: `spikes/fluidaudio-s3/.build/release/fluidaudio-s3`

## Run

```bash
./.build/release/fluidaudio-s3 <input.wav> <output.rttm> <uri> [--threshold <double>]
```

- `<input.wav>` — **must be 16 kHz mono PCM16**. The CLI validates the WAV
  header and hard-errors with the exact `ffmpeg` re-decode command if it
  doesn't match, rather than resampling silently.
- `<output.rttm>` — path to write standard RTTM lines to.
- `<uri>` — the RTTM `<uri>` field (meeting/recording id).
- `--threshold <double>` — optional override for FluidAudio's AHC clustering
  threshold (community-1 default `0.6`; valid range `(0, sqrt(2)]`).

On first run, FluidAudio downloads + compiles its CoreML model bundle
(pyannote community-1: segmentation + fbank + embedding + PLDA-rho models,
~21 MB) into `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`
and reuses it on subsequent runs.

### Example (seed meeting, "Adhoc with Nia")

The rig's pre-decoded WAV lives at
`tools/diarization-sweep/work/<meeting-id>.wav` when a sweep has already run.
For a from-scratch run against the raw recording:

```bash
ffmpeg -i "/Users/paul.foxreeks/Movies/meetily-recordings/Meeting 2026-07-14_15-38-49_2026-07-14_21-38/audio.mp4" \
  -ar 16000 -ac 1 -y spikes/fluidaudio-s3/work/adhoc-nia-16k.wav

cd spikes/fluidaudio-s3
./.build/release/fluidaudio-s3 work/adhoc-nia-16k.wav work/adhoc-nia.rttm adhoc-nia --threshold 0.6
```

Verified output (2026-07-17, seed 2-speaker "Adhoc with Nia" recording,
~9m55s / 9,525,589 samples @ 16 kHz):

```
--- fluidaudio-s3 summary ---
segments:            63
distinct speakers:   3 (S1, S2, S3)
total speech (s):    533.7
model cache path:    /Users/paul.foxreeks/Library/Application Support/FluidAudio/Models
elapsed (s):         19.7
RTTM written to:     work/adhoc-nia.rttm
```

First 15 RTTM lines:

```
SPEAKER adhoc-nia 1 0.577 12.564 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 13.430 11.562 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 25.484 10.306 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 36.112 17.895 <NA> <NA> S2 <NA> <NA>
SPEAKER adhoc-nia 1 54.278 13.277 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 68.998 10.136 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 80.204 1.375 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 82.054 17.182 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 99.728 32.275 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 132.462 6.570 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 139.355 14.856 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 154.380 10.832 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 165.840 1.986 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 167.929 2.479 <NA> <NA> S1 <NA> <NA>
SPEAKER adhoc-nia 1 171.494 18.132 <NA> <NA> S1 <NA> <NA>
```

Speaker-time breakdown at default threshold 0.6:

| Speaker | Segments | Total time |
|---|---|---|
| S1 | 50 | 398.8s |
| S2 | 12 | 132.6s |
| S3 | 1  | 2.3s |

3 distinct labels came out at the default threshold, not the expected 2 —
`S3` is a single 2.3s segment, almost certainly a spurious singleton cluster
rather than a real third speaker (the seed meeting is known 2-speaker from
prior sweeps, per `MEMORY.md`'s note that the sherpa-onnx S3 seed scored
1.0000 stamp accuracy). This is exactly the kind of threshold-sensitivity
question the real S3 sweep (scoring against the hand-labelled reference with
`tools/diarization-sweep/der.py`, sweeping `--threshold`) is meant to
characterize — this spike only proves the pipeline runs end-to-end and
emits usable RTTM; it does not itself tune or validate accuracy.

## Build/runtime notes for the record

- **No Metal/GPU build step** — CoreML compiles its `.mlmodelc` at
  `prepareModels()` runtime (Neural Engine + GPU dispatch handled by
  `MLModelConfiguration(computeUnits: .all)` inside FluidAudio), not at
  `swift build` time. This sidesteps the MLX `.metallib` staging issue the
  `mlx-swift-s1` spike had to work around. Internally the offline pipeline
  runs segmentation + embedding extraction concurrently via `Task.detached`,
  then a CPU-side AHC + VBx clustering pass (Accelerate/BLAS, no CoreML) to
  produce final speaker assignments.
- **`@preconcurrency import CoreML`** and a `nonisolated(unsafe)` model
  cache are present *inside* FluidAudio's own `OfflineDiarizerManager` (not
  code in this spike) — a Swift 6 strict-concurrency accommodation for
  CoreML's non-`Sendable` `MLModel`, justified in FluidAudio's own comments.
  Nothing in this spike's own `main.swift` needed such an escape hatch.
- **No entitlements needed** — a plain SwiftPM CLI, no sandbox, no
  microphone/screen/calendar TCC prompts; it only reads a WAV file from disk
  and downloads CoreML weights over HTTPS on first run.
- **Package.swift pins:** `FluidAudio` exact `0.15.5`. Bump deliberately if a
  later S3 iteration needs it — FluidAudio's diarization internals (chunking,
  VBx clustering, zero-vote re-embed) are actively evolving upstream.
