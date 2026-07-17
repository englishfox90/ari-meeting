#!/usr/bin/env python3
"""
Run the sherpa-onnx diarization recipe (the `diarize-helper` sidecar + the
app's post-processing) over the labeled reference set, across a small
parameter sweep, and write hypothesis RTTMs for scoring by `der.py`.

## What's actually sweepable

Read `diarize-helper/src/main.rs` (the NDJSON wire protocol) + the app's
`frontend/src-tauri/src/diarization/tuning.rs` / `commands.rs` to find the
real knobs — nothing here is guessed:

- **`cluster_threshold`** (sidecar-side, sent as the `diarize` request's
  `threshold` field). AUTO-mode-only (`num_speakers: null`); ignored whenever
  `num_speakers` pins an exact count. Higher = FEWER clusters (more merging).
  App default (`DEFAULT_CLUSTER_THRESHOLD` in tuning.rs): **0.9**.
- **`merge_threshold`** (app-side, `postmerge.py`'s port of
  `postprocess.rs`'s greedy centroid post-merge cutoff). App default
  (`DEFAULT_MERGE_THRESHOLD`): **0.7**.
- **`floor_abs_secs` / `floor_frac`** (app-side speech-time floor). App
  defaults: **10.0s** / **0.02** (2% of total speech). Sweepable too but not
  swept by default here (they rarely move the needle on a clean 2-speaker
  seed meeting) — pass `--floor-abs-secs` / `--floor-frac` to override.
- **`num_speakers`** — this rig always runs the sidecar in AUTO mode
  (`num_speakers: null`) to match the app's shipping default
  (`speakerCount: "auto"` per `tuning.rs`'s `DiarTuning::default()`). Forcing
  an exact count (Fixed/Calendar mode) is a different code path (`apply_merge
  = false`) — out of scope for the parity sweep, which is measuring the
  default auto pipeline.

Everything else (the pyannote segmentation model, the CAM++ embedding model,
`reassign_min_cosine`) is a fixed part of the recipe today; the sidecar
exposes no additional per-request knobs (confirmed by reading main.rs's
`Request::Diarize` struct — only `wav_path`, `num_speakers`, `threshold`).

## Pipeline per (meeting, threshold, merge_threshold)

1. Decode `<folder_path>/audio.mp4` -> 16 kHz mono WAV via ffmpeg, cached in
   `work/<meeting-id>.wav` (audio decode is threshold-independent, done once).
2. Spawn `diarize-helper`, send one `{"type":"diarize", "num_speakers":null,
   "threshold":<t>}` request, capture the raw `segments`+`clusters` response
   (cached per-threshold in `work/<meeting-id>-raw-ct<t>.json`, since the
   sidecar call is the expensive/nondeterministic step and merge_threshold
   sweeping over the SAME raw response is free).
3. Run `postmerge.postprocess(...)` over that raw response with the given
   `merge_threshold` (+ floor knobs), `apply_merge=True` (auto mode).
4. Write `hypotheses/sherpa/ct<t>_mt<m>/<meeting-id>.rttm`.

## Usage

    uv run --with numpy python3 run_sweep.py --meeting meeting-d894f3ce-2ffa-4b34-bba6-1265804df866
    uv run --with numpy python3 run_sweep.py --all
    uv run --with numpy python3 run_sweep.py --all --cluster-thresholds 0.7,0.8,0.9 --merge-thresholds 0.6,0.7,0.8
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import postmerge  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
WORK_DIR = HERE / "work"
HYPOTHESES_DIR = HERE / "hypotheses"
MANIFEST_PATH = HERE / "references" / "manifest.json"

DEFAULT_DIARIZE_HELPER = REPO_ROOT / "diarize-helper" / "target" / "release" / "diarize-helper"
DEFAULT_MODELS_DIR = Path(
    os.path.expanduser("~/Library/Application Support/com.meetily.ai/models/diarization")
)
DEFAULT_SEGMENTATION_MODEL = DEFAULT_MODELS_DIR / "sherpa-onnx-pyannote-segmentation-3-0.onnx"
DEFAULT_EMBEDDING_MODEL = DEFAULT_MODELS_DIR / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"


def decode_to_wav(audio_path: Path, wav_path: Path) -> None:
    if wav_path.exists():
        return
    wav_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(audio_path),
        "-ac", "1", "-ar", "16000",
        str(wav_path),
    ]
    subprocess.run(cmd, check=True)


def run_diarize_helper(
    helper_bin: Path,
    seg_model: Path,
    emb_model: Path,
    wav_path: Path,
    threshold: float,
) -> dict:
    """Spawns diarize-helper, sends one diarize request, returns the parsed
    `segments` JSON response. Raises on an `error` response."""
    req = json.dumps(
        {"type": "diarize", "wav_path": str(wav_path), "num_speakers": None, "threshold": threshold}
    )
    proc = subprocess.run(
        [str(helper_bin), "--segmentation", str(seg_model), "--embedding", str(emb_model)],
        input=req + "\n",
        capture_output=True,
        text=True,
        timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"diarize-helper exited {proc.returncode}: stderr={proc.stderr!r}")
    line = None
    for candidate in proc.stdout.splitlines():
        candidate = candidate.strip()
        if candidate:
            line = candidate
            break
    if line is None:
        raise RuntimeError(f"diarize-helper produced no stdout; stderr={proc.stderr!r}")
    resp = json.loads(line)
    if resp.get("type") == "error":
        raise RuntimeError(f"diarize-helper error: {resp.get('message')}")
    if resp.get("type") != "segments":
        raise RuntimeError(f"unexpected response type {resp.get('type')!r}: {resp}")
    return resp


def get_raw_response(
    helper_bin: Path, seg_model: Path, emb_model: Path,
    wav_path: Path, meeting_id: str, threshold: float,
) -> dict:
    """Cache the raw sidecar response per (meeting, threshold) — expensive and
    the merge_threshold sweep doesn't need to re-run the sidecar."""
    cache_path = WORK_DIR / f"{meeting_id}-raw-ct{threshold}.json"
    if cache_path.exists():
        return json.loads(cache_path.read_text())
    resp = run_diarize_helper(helper_bin, seg_model, emb_model, wav_path, threshold)
    cache_path.write_text(json.dumps(resp))
    return resp


def apply_postmerge(
    raw: dict,
    meeting_id: str,
    merge_threshold: float,
    floor_abs_secs: float,
    floor_frac: float,
    out_path: Path,
) -> tuple[int, int]:
    import numpy as np

    segments = [postmerge.Seg(start=s["start"], end=s["end"], speaker=s["speaker"]) for s in raw["segments"]]
    clusters = [
        postmerge.ClusterIn(speaker=c["speaker"], centroid=np.array(c["centroid"], dtype=np.float32))
        for c in raw["clusters"]
    ]
    result = postmerge.postprocess(
        segments,
        clusters,
        merge_threshold=merge_threshold,
        floor_abs_secs=floor_abs_secs,
        floor_frac=floor_frac,
        apply_merge=True,  # auto mode — matches the app's speakerCount:"auto" default
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for s in sorted(result.segments, key=lambda s: s.start):
        dur = s.end - s.start
        lines.append(f"SPEAKER {meeting_id} 1 {s.start:.3f} {dur:.3f} <NA> <NA> {s.speaker} <NA> <NA>")
    out_path.write_text("\n".join(lines) + ("\n" if lines else ""))
    return len(clusters), len(result.clusters)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--meeting", help="run one meeting id from the manifest")
    ap.add_argument("--all", action="store_true", help="run every meeting in the manifest")
    ap.add_argument("--verified-only", action="store_true", help="restrict --all to verified:true meetings")
    ap.add_argument("--cluster-thresholds", default="0.9", help="comma list, e.g. 0.7,0.8,0.9")
    ap.add_argument("--merge-thresholds", default="0.7", help="comma list, e.g. 0.6,0.7,0.8")
    ap.add_argument("--floor-abs-secs", type=float, default=postmerge.DEFAULT_FLOOR_ABS_SECS)
    ap.add_argument("--floor-frac", type=float, default=postmerge.DEFAULT_FLOOR_FRAC)
    ap.add_argument("--helper-bin", default=str(DEFAULT_DIARIZE_HELPER))
    ap.add_argument("--segmentation-model", default=str(DEFAULT_SEGMENTATION_MODEL))
    ap.add_argument("--embedding-model", default=str(DEFAULT_EMBEDDING_MODEL))
    ap.add_argument("--manifest", default=str(MANIFEST_PATH))
    args = ap.parse_args()

    if not args.meeting and not args.all:
        ap.error("pass --meeting <id> or --all")

    helper_bin = Path(args.helper_bin)
    seg_model = Path(args.segmentation_model)
    emb_model = Path(args.embedding_model)
    for label, p in [("diarize-helper binary", helper_bin), ("segmentation model", seg_model), ("embedding model", emb_model)]:
        if not p.exists():
            print(f"error: {label} not found at {p}", file=sys.stderr)
            return 1
    if shutil.which("ffmpeg") is None:
        print("error: ffmpeg not found on PATH", file=sys.stderr)
        return 1

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"error: manifest not found at {manifest_path} — run extract_reference.py first", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())["meetings"]

    if args.meeting:
        meetings = [m for m in manifest if m["meeting_id"] == args.meeting]
        if not meetings:
            print(f"error: {args.meeting!r} not in manifest", file=sys.stderr)
            return 1
    else:
        meetings = manifest
        if args.verified_only:
            meetings = [m for m in meetings if m["verified"]]

    cluster_thresholds = [float(x) for x in args.cluster_thresholds.split(",")]
    merge_thresholds = [float(x) for x in args.merge_thresholds.split(",")]

    WORK_DIR.mkdir(parents=True, exist_ok=True)

    for m in meetings:
        meeting_id = m["meeting_id"]
        audio_path = m.get("audio_path")
        if not audio_path or not Path(audio_path).exists():
            print(f"skip {meeting_id}: audio not found at {audio_path!r}", file=sys.stderr)
            continue

        wav_path = WORK_DIR / f"{meeting_id}.wav"
        print(f"[{meeting_id}] decoding {audio_path} -> {wav_path}", file=sys.stderr)
        decode_to_wav(Path(audio_path), wav_path)

        for ct in cluster_thresholds:
            print(f"[{meeting_id}] running diarize-helper (cluster_threshold={ct})", file=sys.stderr)
            raw = get_raw_response(helper_bin, seg_model, emb_model, wav_path, meeting_id, ct)
            n_raw_clusters = len(raw["clusters"])
            for mt in merge_thresholds:
                params = f"ct{ct}_mt{mt}"
                out_path = HYPOTHESES_DIR / "sherpa" / params / f"{meeting_id}.rttm"
                n_raw, n_surv = apply_postmerge(
                    raw, meeting_id, mt, args.floor_abs_secs, args.floor_frac, out_path
                )
                print(
                    f"  ct={ct} mt={mt}: {n_raw_clusters} raw clusters -> {n_surv} surviving -> {out_path}",
                    file=sys.stderr,
                )

    print("\ndone.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
