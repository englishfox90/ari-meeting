# diarize-helper — Engine Spike Notes

De-risking the diarization engine: **sherpa-onnx offline speaker diarization +
speaker-embedding extraction, driven from Rust, as a standalone sidecar crate**
(mirrors `llama-helper/`, `ari-notch/`, `apple-helper/`).

**Verdict up front: SIDECAR CONFIRMED.** sherpa-onnx 1.13.4 built and linked on
this Apple Silicon machine on the first native try; the only fix needed was one
type in *our* code. ONNX Runtime is fully isolated (statically bundled into this
binary — see "Linkage" below), which is the entire reason we chose the sidecar.

---

## 1. Build result (the real de-risk)

| Item | Result |
|------|--------|
| `cd diarize-helper && cargo build --release` | ✅ **Success** (after 1 trivial local type fix) |
| `sherpa-onnx-sys` 1.13.4 compile + link | ✅ compiled, no system deps needed |
| `sherpa-onnx` 1.13.4 compile | ✅ |
| Prebuilt native lib | ✅ auto-downloaded by the sys build script (no `SHERPA_ONNX_LIB_DIR` set) |
| `cargo test --release` | ✅ 5/5 protocol tests pass |
| `./target/release/diarize-helper --probe` | ✅ emits valid `probe_result` JSON, `runtime_ok:true` |
| Binary size | 22 MB (ONNX Runtime + kaldi + fst statically bundled) |

**The one build error** was mine, not the toolchain:
`OfflineSpeakerSegmentationPyannoteModelConfig.model` is `Option<String>`, I
passed `String`. Fixed to `Some(seg)`. No native/link/download blockers at all.

### What the build script did automatically
- `sherpa-onnx-sys` printed `cargo:rerun-if-env-changed=SHERPA_ONNX_LIB_DIR`,
  then (env unset) downloaded and staged the prebuilt archive
  **`sherpa-onnx-v1.13.4-osx-arm64-static-lib`** into
  `target/sherpa-onnx-prebuilt/…/lib/` and emitted `rustc-link-lib=static=…`
  for each component (`sherpa-onnx-c-api`, `sherpa-onnx-core`, `onnxruntime`,
  kaldi/fst/kissfft/espeak, etc.).
- Requires network on first clean build. To build fully offline / pin the lib,
  set `SHERPA_ONNX_LIB_DIR` to a dir already containing these `.a` files.

### Linkage — proof of ONNX isolation
`otool -L target/release/diarize-helper` lists **only** system libraries:
`libc++.1.dylib`, `Foundation`, `libSystem.B.dylib`, `CoreFoundation`.
There is **no external `libonnxruntime.dylib` and no sherpa dylib** — the
bundled `libonnxruntime.a` is statically linked *inside* this binary. It shares
nothing with the main app's `ort` 2.0.0-rc.10. Sidecar isolation goal met.

---

## 2. Confirmed sherpa-onnx API surface (crate `sherpa-onnx` = "1.13.4")

Verified against docs.rs and by compiling. Features: **`static`** (default,
what we use) and `shared`. We declare `default-features = false, features =
["static"]` and re-expose both as crate features.

### Diarization
```rust
// Public fields, not builders — construct via `..Default::default()`.
OfflineSpeakerDiarizationConfig {
    segmentation: OfflineSpeakerSegmentationModelConfig {
        pyannote: OfflineSpeakerSegmentationPyannoteModelConfig {
            model: Option<String>,   // ← path to pyannote model.onnx  (NOTE: Option)
            ..Default::default()
        },
        num_threads: i32,
        debug: bool,
        provider: Option<String>,    // None → CPU
        ..
    },
    embedding: SpeakerEmbeddingExtractorConfig { model: Some(path), num_threads, debug, provider },
    clustering: FastClusteringConfig { num_clusters: i32, threshold: f32 },
    min_duration_on: f32,
    min_duration_off: f32,
}

OfflineSpeakerDiarization::create(&cfg) -> Option<Self>
    .sample_rate() -> i32                       // models report 16000
    .process(&[f32]) -> Option<OfflineSpeakerDiarizationResult>

OfflineSpeakerDiarizationResult
    .num_speakers() -> i32
    .num_segments() -> i32
    .sort_by_start_time() -> Vec<OfflineSpeakerDiarizationSegment>

OfflineSpeakerDiarizationSegment { pub start: f32, pub end: f32, pub speaker: i32 }
```

**num_speakers vs threshold** (the key control): both live on
`FastClusteringConfig`, set at **construction** time (not per-`process()`):
- Known count → `num_clusters = N`, `threshold` ignored.
- Unknown → `num_clusters = -1` (auto), `threshold = 0.5` decides the count.

Because it's construction-time, the sidecar caches one `OfflineSpeakerDiarization`
per distinct num_speakers value.

### Embedding
```rust
SpeakerEmbeddingExtractorConfig { model: Option<String>, num_threads: i32, debug: bool, provider: Option<String> }

SpeakerEmbeddingExtractor::create(&cfg) -> Option<Self>
    .dim() -> i32                        // 512 for CAM++
    .create_stream() -> Option<OnlineStream>
    .is_ready(&stream) -> bool
    .compute(&stream) -> Option<Vec<f32>>

OnlineStream
    .accept_waveform(sample_rate: i32, samples: &[f32])
    .input_finished()
```
Embedding flow: `create_stream` → `accept_waveform(16000, &samples)` →
`input_finished()` → `is_ready` → `compute` → `Vec<f32>` (len == `dim()`).

> Note: sherpa also exposes a `Wave` loader, but we deliberately read WAV with
> the tiny pure-Rust `hound` crate instead, so our only dependency on the
> sherpa API is the diarization/embedding calls above. Keeps the surface small.

---

## 3. Model files + download commands (run manually)

Both models are **16 kHz mono**. Download at runtime into the app-data models
dir like the app's other weights; pass the paths to this sidecar via
`--segmentation` / `--embedding` (or `DIARIZE_SEGMENTATION_MODEL` /
`DIARIZE_EMBEDDING_MODEL`).

**Segmentation — pyannote 3.0** (`model.onnx` after extract):
```bash
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
tar xf sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
# → sherpa-onnx-pyannote-segmentation-3-0/model.onnx
```

**Embedding — CAM++ 512-dim** (Apache-2.0, the model OpenWhispr uses):
```bash
wget https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
```
(Also mirrored at `huggingface.co/csukuangfj/speaker-embedding-models`. Note the
upstream release tag is misspelled `speaker-recongition-models` — that is
correct as-is. A zh-cn-only variant `3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx`
also exists; the `zh_en_…_advanced` one is the bilingual pick.)

### End-to-end manual verification (for the user, once models are downloaded)
```bash
cd diarize-helper
SEG=/path/to/sherpa-onnx-pyannote-segmentation-3-0/model.onnx
EMB=/path/to/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx

# probe: should report runtime_ok:true and embedding_dim:512
./target/release/diarize-helper --probe --segmentation "$SEG" --embedding "$EMB"

# diarize a 16 kHz mono WAV (auto speaker count):
echo '{"type":"diarize","wav_path":"/abs/test-16k-mono.wav","num_speakers":null}' \
  | ./target/release/diarize-helper --segmentation "$SEG" --embedding "$EMB"

# single embedding:
echo '{"type":"embed","wav_path":"/abs/test-16k-mono.wav"}' \
  | ./target/release/diarize-helper --embedding "$EMB"
```
> A real diarization run over actual model files was **not** performed in this
> spike (models not present on the machine). Everything up to model inference —
> compile, link, runtime init, probe, protocol — is verified. The commands above
> are the remaining manual step.

---

## 4. Wire protocol (NDJSON, snake_case — house convention)

One JSON object per line, stdin→stdout. stderr is logs only.

| Request | Response |
|---------|----------|
| `{"type":"embed","wav_path":"…"}` | `{"type":"embedding","dim":512,"vector":[…]}` |
| `{"type":"diarize","wav_path":"…","num_speakers":N\|null}` | `{"type":"segments","segments":[{"start":f64,"end":f64,"speaker":"spk_0"},…],"clusters":[{"speaker":"spk_0","dim":512,"centroid":[f32,…]},…]}` |
| `{"type":"ping"}` | `{"type":"pong"}` |
| `{"type":"shutdown"}` | `{"type":"goodbye"}` |
| (malformed) | `{"type":"error","message":"…"}` |
| `--probe` flag | `{"type":"probe_result","runtime_ok":bool,"embedding_dim":512,…}` |

Speaker labels are surfaced as `spk_<i32>` strings (sherpa returns an integer
speaker index).

**`clusters` (added for cross-meeting re-ID).** The `diarize` response now
carries, alongside `segments`, one `clusters` entry per distinct speaker label.
Each is the **mean of that cluster's CAM++ segment embeddings, L2-normalized**
(`dim` = extractor `dim()`, 512 for CAM++). Computed by grouping segments by
speaker, slicing the 16 kHz sample buffer to `[start*sr, end*sr)` per segment
and concatenating, then running the embedding extractor over that concatenated
audio. `spk_<i>` indices are per-file only; the app matches these unit-length
centroids (cosine = dot product) against stored per-person voiceprints for
F1/F2 identity. A degenerate cluster with no usable audio (or audio too short
for the extractor) yields a **zero vector of length `dim`** — never a panic —
which the app's matcher treats as no-match. `embed` and `--probe` responses are
**unchanged**.

---

## 5. Isolation / workspace decision (reported as requested)

- The repo **is** a Cargo workspace (root `Cargo.toml`, `resolver = "2"`,
  explicit `members = ["frontend/src-tauri", "llama-helper"]`). Note `llama-helper`
  is itself a *member* — but it's a pure-Rust crate, cheap to compile.
- For `diarize-helper` I did **not** add it to that members list. Instead the
  crate's own `Cargo.toml` carries an **empty `[workspace]` table**, making it
  its own workspace root. Because the parent lists members explicitly and
  **nothing path-depends on diarize-helper**, the parent never pulls it in.
  Result: `cargo check` / `cargo build` / `cargo test` at the repo root (the
  project's standard checks) do **not** compile sherpa-onnx, and the main app's
  link graph never sees ONNX-Runtime-#2. Build it explicitly:
  `cd diarize-helper && cargo build --release`.
- No existing file was touched. `frontend/src-tauri/` was only read (sidecar
  registration into `tauri.conf.json` `externalBin` is a later phase).

---

## 6. `ort` conflict check (the whole point of the sidecar)

The main app links **`ort` 2.0.0-rc.10** (Rust crate) for Parakeet. sherpa-onnx
pulls **no `ort` crate at all** — it links a *C* ONNX Runtime static archive
(`libonnxruntime.a`) bundled in the prebuilt sherpa lib. There is therefore no
Cargo-level version conflict and, because they're separate binaries/processes,
no symbol conflict. Confirmed: two independent ONNX Runtimes, zero overlap.

---

## 7. Open questions for the architect

1. **Audio input contract.** Sidecar hard-requires **16 kHz mono WAV**. The app
   persists `mic.m4a` / `system.m4a` (48 kHz AAC). Who transcodes → 16k mono
   WAV: the existing ffmpeg sidecar (a temp WAV per track), or add symphonia
   decode+resample in Rust? Recommend ffmpeg sidecar → temp WAV; simplest.
2. **num_speakers source.** Auto-clustering (`threshold`) vs. constraining to
   the calendar attendee count (F4). PRD's "calendar priors constrain the label
   space" maps cleanly onto passing `num_speakers = attendee_count`.
3. **`threshold` default.** We used `0.5`. Needs tuning on real meeting audio;
   expose it in the protocol later if 0.5 over/under-splits.
4. **CoreML provider.** Left `provider = None` (CPU). sherpa accepts
   `Some("coreml")`; worth benchmarking on M-series once wired.
5. **Model versioning / offline builds.** The sys build script downloads the
   prebuilt `-lib` archive from GitHub on first build. For reproducible/offline
   CI, vendor the `-static-lib` archive and set `SHERPA_ONNX_LIB_DIR`.
6. **Speaker-index stability.** `speaker` indices are per-`process()` (per file)
   — they are NOT persistent identities. Cross-meeting re-ID (F1/F2) is done by
   comparing the `embed` vectors (CAM++ centroids), not by these indices.
7. **Licensing.** sherpa-onnx = Apache-2.0; bundled ONNX Runtime = MIT; CAM++ =
   Apache-2.0; pyannote-segmentation-3.0 — verify its redistribution terms
   before shipping (MIT model weights on the k2-fsa mirror, but confirm).

---

## Files
- `diarize-helper/Cargo.toml` — isolated crate, `sherpa-onnx` 1.13.4 static.
- `diarize-helper/src/main.rs` — NDJSON sidecar, `--probe`, embed + diarize.
- `diarize-helper/SPIKE_NOTES.md` — this file.
