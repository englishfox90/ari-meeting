# tools/

Standalone dev tools that operate *outside* the Tauri app (not registered as
Tauri commands, not part of the Rust module tree). Run with `python3` / `uv`
from the repo root — except `prompt-harness/`, which is Node (see below).

## diarization_calibrate.py

Calibrates the re-ID matcher thresholds (`MatchConfig::auto_threshold` /
`suggest_threshold` / `margin` in
`frontend/src-tauri/src/diarization/matching.rs`, currently `0.70` / `0.55` /
`0.08`) against real, labeled data instead of guesses.

### What it does

It reads the app's SQLite DB **read-only** (`mode=ro&immutable=1` — it never
writes, and `PRAGMA query_only = ON` is set as a second guard) and mines:

- `speakers` rows with `person_id NOT NULL` — voiceprints the user has
  confirmed belong to a specific person.
- `speaker_segments.embedding` for those speakers, joined by `speaker_id` —
  one embedding per within-meeting cluster.

From that it builds two cosine-similarity populations:

- **same-person pairs** — cluster embeddings belonging to the *same* assigned
  person, preferring cross-meeting pairs (the actual re-ID scenario) and
  falling back to within-meeting pairs only if a person has just one meeting
  so far.
- **different-person pairs** — cluster embeddings from two *different*
  assigned persons.

It reports both distributions (mean/median/p5/p95 + an ASCII histogram),
then recommends:

- `auto_threshold` = p5 of the same-person distribution (floored at 0.5) —
  auto-confirm should sit at/below where genuine matches actually land.
- `suggest_threshold` = the equal-error-rate crossover between the two
  distributions (where false-accept rate ≈ false-reject rate).
- `margin` = half the gap between the two distributions' medians, clamped to
  `[0.05, 0.15]`.

It also flags **suspect enrollments**: any assigned person whose own
clusters don't agree with each other (mean intra-person cosine < 0.5),
which usually means a mis-assignment happened somewhere.

Results are labeled **LOW CONFIDENCE** whenever there are fewer than 5
labeled persons or fewer than 20 total pairs — treat those numbers as
directional, not something to paste into `MatchConfig` yet.

### Usage

```bash
# Default: reads ~/Library/Application Support/com.meetily.ai/meeting_minutes.sqlite
uv run --with numpy python3 tools/diarization_calibrate.py

# Explicit DB path
uv run --with numpy python3 tools/diarization_calibrate.py --db /path/to/meeting_minutes.sqlite

# Machine-readable output
uv run --with numpy python3 tools/diarization_calibrate.py --json
```

(`uv run --with numpy` is the easiest way to get numpy without touching your
system Python; a plain venv with `pip install numpy` works too — the script
itself is stdlib + numpy only, no other deps.)

If there's no labeled data yet (no speakers assigned to persons), it prints
a message telling you to assign a few speakers in the app first, rather than
crashing.

### Re-calibration workflow

1. Use the app normally; whenever the matcher suggests or asks to confirm a
   speaker, assign it to the right person. Every confirmed assignment adds
   ground truth this tool can use.
2. Periodically (e.g. after every batch of ~10+ new assignments, or before a
   diarization-quality push), re-run the tool.
3. Once it reports **not** low-confidence (≥5 labeled persons, ≥20 pairs) and
   the recommended values have stabilized across a couple of runs, hand-edit
   `MatchConfig::default()` in
   `frontend/src-tauri/src/diarization/matching.rs` to the recommended
   `auto_threshold` / `suggest_threshold` / `margin`. This is a deliberate,
   reviewed edit to an upstream-adjacent file (matching.rs is a net-new Ari
   module, not upstream code, so normal edit rules apply) — update the
   doc-comment thresholds mentioned there too, and re-run `cargo test` for
   `diarization::matching` (the existing unit tests hardcode the old
   defaults and will need updating alongside the constants).
4. Re-run this tool again after the config change lands and a new batch of
   assignments accumulates, to confirm the new thresholds are still tracking
   the data (drift can happen if enrollment or embedding-model changes).

### Data-quality notes

- Only speakers with a non-NULL `person_id` count as "labeled" — provisional/
  unconfirmed voiceprints are correctly excluded.
- Multiple `embedding_model`/`dim` groups are analyzed independently and
  reported as separate sections — don't average across embedding models,
  since similarity scales aren't comparable between them.
- Small `n` is expected early on; the tool is designed to be re-run
  repeatedly as the DB accumulates more confirmed assignments, not to be
  trusted on a single early run.

## diarization-sweep/

The DER/parity eval rig for Swift-migration Phase-0 spike **S3** (deciding
whether a future FluidAudio CoreML pyannote diarizer can hit parity with the
current tuned sherpa-onnx recipe). Extracts verified-correct reference RTTMs
from the DB (per-transcript `speaker_id` + timing, read-only), runs the
`diarize-helper` sidecar + a faithful Python port of the app's post-processing
(`postprocess.rs`) across a small threshold sweep, and scores hypotheses
against references with `pyannote.metrics` DER (+ an overlap-based
stamp-accuracy metric that isn't confounded by independent-VAD boundary
noise). Leaves a clean seam for a future FluidAudio RTTM set to be dropped in
and scored through the exact same path — this tool does NOT integrate
FluidAudio itself (that's S3-proper, in Swift/CoreML, later).

```bash
cd tools/diarization-sweep
uv run --with numpy python3 extract_reference.py --all
uv run --with numpy python3 run_sweep.py --all
uv run --with pyannote.metrics --with numpy python3 der.py --engine sherpa --label ct0.9_mt0.7
```

Full usage, the ground-truth model (parity-vs-current-shipping, not
absolute DER), the read-only DB posture, and the Adhoc-Nia end-to-end
validation are in `diarization-sweep/README.md`.

## prompt-harness/ (Node, not Python)

The eval "measuring stick" for Swift-migration Phase-0 spike **S1**
(deciding whether an MLX summary model can match the current Qwen 3.5 4B
GGUF summary quality). Reconstructs the app's real final-report summary
prompt from current source, drives it against the llama-helper (Qwen
baseline), apple-helper (FoundationModels), and Ollama backends over real
meetings pulled read-only from the app's SQLite DB, and provides a blind
A/B rating tool for the pass/fail bar. Does not add an MLX backend itself —
see `prompt-harness/README.md`'s "Adding the MLX backend (S1)" section for
that hookup.

```bash
cd tools/prompt-harness
node extract.mjs
node run.mjs --backend llama --label baseline
node abtest.mjs --baseline runs/llama-baseline --candidate runs/<mlx-run>
```

Full usage, verified protocol facts, and privacy posture (read-only DB,
gitignored transcript-bearing outputs) are in `prompt-harness/README.md`.
