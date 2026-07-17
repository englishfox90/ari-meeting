# tools/diarization-sweep/

The **Phase-0 measuring stick for S3** of the Swift migration (see
`~/.claude/…/swift-migration-and-rebrand.md` / the migration plan): before
integrating FluidAudio (CoreML pyannote) as a candidate replacement diarizer
in Swift/CoreML, we need a rig that can say, objectively, whether a
candidate engine's output is *at least as good as* what the app ships today.

This tool builds and validates that rig using the CURRENT sherpa-onnx recipe
(`diarize-helper` + the app's post-processing) as both the thing being
measured and, on the seed meeting, a self-check that the rig's numbers mean
what we think they mean. **It does not integrate FluidAudio** — that is
S3-proper, later, in Swift. This tool leaves a clean seam for a
FluidAudio-produced RTTM to be dropped in and scored through the exact same
path (see "Adding FluidAudio (S3)" below).

## Ground-truth model — READ THIS FIRST

**S3 is a parity-vs-current-shipping test, NOT an absolute DER-vs-human-labels
test.** (Decided by Paul, 2026-07-16.)

The "reference" RTTM for each meeting is the **verified-correct CURRENT APP
diarization output** — extracted per-transcript-row from the DB (`speaker_id`
+ `audio_start_time`/`audio_end_time` on `transcripts`), after a human (Paul)
has confirmed the labels are right. The question this rig answers is:

> "Does a candidate engine match what we already ship and trust?"

**not**

> "Is this diarization objectively correct against an independently
> human-transcribed corpus?"

The confirmed seed reference is meeting
`meeting-d894f3ce-2ffa-4b34-bba6-1265804df866` ("Adhoc with Nia" — 2
speakers, ~10 min, auto-diarized, Paul-confirmed correct). **This is the EASY
end of the difficulty curve** — good for building and validating the
plumbing, but the labeled set must grow to include 3+-speaker and
remote-mixed-audio cases before an S3 go/no-go verdict counts for anything.
The other 8 meetings in the DB have been extracted into
`references/manifest.json` as `verified: false` candidates — they need Paul's
explicit confirmation (scanning their transcript + speaker labels for
correctness) before they're promoted to the verified set.

## Read-only DB posture

Every read of `~/Library/Application Support/com.meetily.ai/meeting_minutes.sqlite`
opens the connection with `mode=ro&immutable=1` in the SQLite URI **and**
sets `PRAGMA query_only = ON` (same posture as the existing
`tools/diarization_calibrate.py`, which this tool mirrors). `extract_reference.py`
additionally runs a write-probe against its own connection and refuses to
proceed if a write somehow succeeds. This tool never has a code path that
writes to the app's database.

## What's committed vs. gitignored

- **Committed**: `references/*.rttm` + `references/manifest.json`. RTTM is
  just `start duration <NA> <NA> speaker-label <NA> <NA>` per line — **no
  transcript text** — confirmed by inspection before committing.
- **Gitignored** (`work/`, `hypotheses/`, `results/`): all audio-derived or
  regenerable. `work/` holds decoded 16 kHz mono WAVs and cached raw sidecar
  JSON responses; `hypotheses/` holds hypothesis RTTMs per engine/param
  combo; `results/` holds DER score JSON.

## Pipeline

```
extract_reference.py  →  references/<meeting-id>.rttm + manifest.json   (DB, read-only)
run_sweep.py           →  hypotheses/sherpa/<params>/<meeting-id>.rttm  (ffmpeg decode + diarize-helper + postmerge.py)
der.py                 →  results/<engine>-<label>.json                (pyannote.metrics DER + stamp-accuracy)
```

`postmerge.py` is invoked as a library by `run_sweep.py` (not shelled out per
meeting — it's cheap to import), but also works standalone as a CLI over a
raw sidecar JSON response if you want to post-process one file by hand.

### 1. Extract the reference set

```bash
uv run --with numpy python3 extract_reference.py --all
# or a single meeting:
uv run --with numpy python3 extract_reference.py --meeting meeting-d894f3ce-2ffa-4b34-bba6-1265804df866
```

### 2. Run the sherpa baseline sweep

```bash
uv run --with numpy python3 run_sweep.py --all \
    --cluster-thresholds 0.7,0.8,0.9 \
    --merge-thresholds 0.6,0.7,0.8
```

Or just the verified seed meeting with the app's shipping defaults:

```bash
uv run --with numpy python3 run_sweep.py --meeting meeting-d894f3ce-2ffa-4b34-bba6-1265804df866
```

### 3. Score a hypothesis set

```bash
uv run --with pyannote.metrics --with numpy python3 der.py --engine sherpa --label ct0.9_mt0.7
```

`--engine`/`--label` select `hypotheses/<engine>/<label>/*.rttm`. By default
only `verified: true` manifest entries are scored (pass
`--include-unverified` to also see numbers for the unverified candidates —
informational only, they don't count toward any S3 verdict yet).

## What's actually sweepable (read from source, not guessed)

Confirmed by reading `diarize-helper/src/main.rs` (the sidecar's NDJSON wire
protocol), `frontend/src-tauri/src/diarization/tuning.rs`, and
`frontend/src-tauri/src/diarization/commands.rs`:

| Knob | Where it lives | App default | Swept here? |
|------|-----------------|-------------|-------------|
| `cluster_threshold` | sidecar-side (`diarize` request's `threshold` field, AUTO mode only) | 0.9 | yes (`--cluster-thresholds`) |
| `merge_threshold` | app-side post-merge (`postprocess.rs` / `postmerge.py`) | 0.7 | yes (`--merge-thresholds`) |
| `floor_abs_secs` / `floor_frac` | app-side speech-time floor | 10.0s / 0.02 | yes, but not default-swept (`--floor-abs-secs`/`--floor-frac`, single value) |
| `num_speakers` | sidecar request field | `null` (auto) in this rig | **no** — this rig always runs AUTO mode to match the app's `speakerCount: "auto"` shipping default. Forced-K (Fixed/Calendar) is a different code path (`apply_merge = false`) and out of scope. |
| segmentation/embedding models, `reassign_min_cosine` | fixed in the recipe | pyannote-3.0 / CAM++, 0.5 | no — the sidecar exposes no per-request knob for these (confirmed: `Request::Diarize` only carries `wav_path`, `num_speakers`, `threshold`) |

## Where post-processing actually lives (verified, not guessed)

Read `diarize-helper/src/main.rs` end-to-end: `Engine::diarize` returns the
sidecar's raw `segments` + per-cluster `centroid`s straight off
`OfflineSpeakerDiarization::process()` — **no merge/floor/relabel logic
anywhere in that file.** The 44-clusters-on-a-1:1 over-splitting problem and
its fix (greedy centroid post-merge + speech-time floor) live entirely
app-side, in `frontend/src-tauri/src/diarization/postprocess.rs`, invoked
from `commands.rs` right after the sidecar call. `postmerge.py` is a faithful
line-by-line port of that Rust module (same defaults, same algorithm order:
greedy merge → speech-time floor → optional max-clusters cap), so this rig's
hypotheses reflect what the app actually ships, not raw unprocessed sherpa
output.

## Validated end-to-end: the Adhoc-Nia self-check

Ran the full loop — extract reference, decode audio, run sherpa via the
sidecar, post-merge, score — on the verified seed meeting at the app's
shipping defaults (`cluster_threshold=0.9`, `merge_threshold=0.7`):

```
meeting                                         DER(collar=0.25)    DER(collar=0.0)  stamp_acc
meeting-d894f3ce-2ffa-4b34-bba6-1265804df866              0.2200             0.2511     1.0000
```

**DER is non-trivial (~0.22–0.25) but `stamp_accuracy` is 1.0000.** Diagnosis
(this is a real property of the rig, not a bug):

- DER's false-alarm/missed-detection components (82s / 23s out of ~508–530s
  total reference speech — the bulk of the error) come from **VAD boundary
  mismatch**, not speaker-labeling error. The reference RTTM's segment
  boundaries are **transcript** segment boundaries (from Parakeet/Whisper's
  own VAD), while a from-scratch sherpa diarization run does **its own
  independent VAD** (the pyannote segmentation model) over the same audio.
  Two different VADs never produce byte-identical speech boundaries, even
  when every speaker label is correct — literal-boundary DER penalizes that
  as false-alarm/missed-detection.
- Confirmed this is exactly what the live app avoids: `stamp_transcripts` in
  `frontend/src-tauri/src/diarization/commands.rs` does **not** adopt the
  diarizer's boundaries. It stamps each *existing* transcript row with
  whichever diarization segment it most overlaps — the operationally
  relevant question is "would this diarization assign the same speaker to
  each transcript line as the verified reference did?", not "do the VAD
  boundaries match exactly?"
- `stamp_accuracy` (`der.py`) answers that question directly: for every
  reference (transcript) segment, find the hypothesis segment it most
  overlaps (mirroring `stamp_transcripts`' overlap rule), build a
  duration-weighted confusion matrix, solve the optimal reference↔hypothesis
  label mapping (Hungarian algorithm), and report matched-duration /
  total-duration. On Adhoc Nia at the shipping defaults: **100% of the
  reference speech duration would be stamped with the correct speaker.**

**Conclusion: the rig is correct.** A faithful re-run of the exact recipe the
app ships reproduces its own labeling with zero disagreement on this
2-speaker seed. DER stays non-zero for a real, understood, and expected
reason (independent-VAD boundary noise) — **not** a label-mapping bug, a
sample-rate/unit bug, or a post-processing mismatch. Both metrics are
reported going forward: DER for the standard/comparable number, stamp_accuracy
as the boundary-noise-immune parity check.

A small param sweep (`cluster_threshold` × `merge_threshold` ∈ {0.7,0.8,0.9} ×
{0.6,0.7,0.8}) confirms the raw sherpa cluster count varies a lot (11–22
clusters pre-merge) but the post-processed, correctly-labeled result is
stable: `stamp_accuracy` stayed in **0.975–1.000** across all 9 combos on
this seed meeting, while DER stayed in a tight 0.22–0.28 band (again, boundary
noise, not label error) — see `results/sherpa-ct*_mt*.json`.

Read-only DB posture and RTTM content were also explicitly checked: a
write-probe against the extraction connection fails (confirmed), and
`references/*.rttm` were grepped for transcript-like text and contain none —
only `SPEAKER <meeting-id> 1 <start> <dur> <NA> <NA> <label> <NA> <NA>` lines.

## Adding FluidAudio (S3)

When the Swift/CoreML FluidAudio integration (S3-proper) is ready to be
compared:

1. Produce RTTMs into `hypotheses/fluidaudio/<label>/<meeting-id>.rttm` —
   same naming convention as the sherpa hypotheses (`<label>` can be a
   version tag like `v1`, or a param combo if FluidAudio exposes tunables).
   If FluidAudio's own output is already app-equivalent post-processed turns
   (no separate merge/floor step needed), that's fine — this rig doesn't
   require a `postmerge.py`-equivalent step for every engine, only that the
   final RTTM represents what would actually ship.
2. Score it through the exact same path:
   ```bash
   uv run --with pyannote.metrics --with numpy python3 der.py --engine fluidaudio --label v1
   ```
3. **The S3 comparison is:** `mean DER(fluidaudio) <= mean DER(sherpa)` on the
   **verified** manifest subset (pass no extra flag — `--verified-only` is
   the default), using the SAME collar (0.25s is the standard; 0.0 is the
   strict number). Sanity-check `stamp_accuracy` too, for the reason
   documented above — a fair race should compare both, since literal-DER can
   penalize a candidate engine's own independent VAD even when its
   speaker-labeling is equally good.
4. Remember the caveat above: a verdict computed only on the 2-speaker Adhoc
   Nia seed is not a real S3 verdict. Grow `references/manifest.json` to
   3+-speaker and remote-mixed-audio cases (verify a handful of the 8
   unverified candidates already sitting in the manifest, or record new
   meetings) before treating any FluidAudio-vs-sherpa comparison as
   decisive.

## Manifest status (as of 2026-07-16)

8 of the app's 9 recorded meetings have usable per-transcript speaker labels
and are in `references/manifest.json` (the 9th, "Metro2", has no labeled
transcript segments and was skipped). Only **1 is `verified: true`** today
(Adhoc with Nia — the seed). The other 7 are `verified: false` and need
Paul's explicit confirmation before they count:

- PM Round up - PR_FAQ or Value Add - July 7, 2026 (43 "speakers" — almost
  certainly a room/attendee-list artifact worth checking, not real diarized
  speakers; needs review before trusting)
- PM Round up - July 14, 2026 (13 speakers — same caveat)
- 1:1 Check-in & Strategic Planning Review (2 speakers)
- Servicing Organization Strategy and Team Performance Review (7 speakers)
- Mentorship Kick Off (2 speakers)
- 1:1 Check-in and Career Development Discussion (2 speakers)
- Brian 1:1 (4 speakers)

## Dependencies

```bash
uv run --with numpy python3 extract_reference.py --all
uv run --with numpy python3 run_sweep.py --all
uv run --with pyannote.metrics --with numpy python3 der.py --engine sherpa --label ct0.9_mt0.7
```

`der.py` falls back to a from-scratch DER implementation (Hungarian optimal
speaker mapping, no collar support) if `pyannote.metrics` isn't available in
the environment — but prefer the library; the fallback is a correctness
safety net, not the primary path.

## Constraints honored

- No product code touched (`frontend/**`, `diarize-helper/src/**` were read,
  never edited).
- No committed binaries, models, or audio.
- `diarize-helper` binary + models used are the same ones the app builds and
  downloads at runtime — this tool does not vendor or rebuild them.
