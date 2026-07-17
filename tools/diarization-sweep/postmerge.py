#!/usr/bin/env python3
"""
Python port of the app's diarization post-processing
(`frontend/src-tauri/src/diarization/postprocess.rs`).

## Why this exists

`diarize-helper` (the sherpa-onnx sidecar) does NOT post-process its own
output — confirmed by reading `diarize-helper/src/main.rs`: `Engine::diarize`
returns the sidecar's raw `segments` + per-cluster `centroid`s straight off
`OfflineSpeakerDiarization::process()`, with no merge/floor/relabel logic
anywhere in that file. All of that lives app-side, in
`frontend/src-tauri/src/diarization/postprocess.rs`, and is invoked from
`frontend/src-tauri/src/diarization/commands.rs` right after the sidecar call.

Because the *app's shipped diarization* is "raw sherpa output + this
post-processing", the sweep rig must replicate the post-processing too —
otherwise the hypothesis it scores is not what the app actually produces, and
a sherpa-vs-reference DER on the seed meeting would be meaningless (the
reference RTTM in this repo IS post-processed app output).

This is a **faithful line-by-line port** of the Rust recipe, not a
reimplementation from spec, to minimize behavioral drift:

1. **Greedy post-merge** (only in auto/threshold mode — skipped when the
   caller pins an exact cluster count): repeatedly merge the pair of clusters
   with the highest centroid cosine >= `merge_threshold` (default 0.7),
   combining centroids as a speech-duration-weighted mean, re-L2-normalized.
2. **Speech-time floor**: dissolve clusters whose total speech is below
   `max(floor_abs_secs=10, floor_frac=0.02 * total speech)`. Each dissolved
   cluster's segments are reassigned to the nearest surviving cluster if
   centroid cosine >= `reassign_min_cosine` (0.5), else dropped.
3. **Optional max_clusters cap** (calendar-attendee upper bound; not used by
   this rig's auto-mode sweep, but ported for completeness / future use):
   after 1+2, if more than `max_clusters` survive, greedily merge the closest
   pairs (ignoring `merge_threshold`) until at/under the cap.

Defaults mirror `PostProcessConfig::default()` / `DiarTuning::default()` in
the Rust source (`tuning.rs` DEFAULT_CLUSTER_THRESHOLD=0.9 is the SIDECAR
input threshold, a separate knob from `merge_threshold` here).

If a future engine (e.g. FluidAudio via a Swift/CoreML pipeline in S3-proper)
already returns app-equivalent post-processed turns, this stage should be a
no-op pass-through for that hypothesis — the CLI below supports `--no-merge`
for exactly that case.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field

try:
    import numpy as np
except ImportError:
    print(
        "error: this tool requires numpy. Try:\n"
        "  uv run --with numpy python3 postmerge.py …",
        file=sys.stderr,
    )
    sys.exit(1)

# ---- Defaults (mirrors PostProcessConfig::default() in postprocess.rs) ----
DEFAULT_MERGE_THRESHOLD = 0.7
DEFAULT_FLOOR_ABS_SECS = 10.0
DEFAULT_FLOOR_FRAC = 0.02
DEFAULT_REASSIGN_MIN_COSINE = 0.5


@dataclass
class Seg:
    start: float
    end: float
    speaker: str


@dataclass
class ClusterIn:
    speaker: str
    centroid: "np.ndarray"


@dataclass
class ClusterOut:
    speaker: str
    dim: int
    centroid: "np.ndarray"


@dataclass
class PostProcessResult:
    segments: list[Seg]
    clusters: list[ClusterOut]


@dataclass
class Working:
    rep: str
    centroid: "np.ndarray"
    duration: float
    members: list[str] = field(default_factory=list)


def cosine_similarity(a: "np.ndarray", b: "np.ndarray") -> float:
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def l2_normalize(v: "np.ndarray") -> "np.ndarray":
    norm = float(np.linalg.norm(v))
    if norm > np.finfo(np.float32).eps:
        return v / norm
    return v


def weighted_mean(a: "np.ndarray", wa: float, b: "np.ndarray", wb: float) -> "np.ndarray":
    if a.shape != b.shape or a.size == 0:
        return a.copy()
    if wa <= 0.0 and wb <= 0.0:
        wa, wb = 1.0, 1.0
    else:
        wa, wb = max(wa, 0.0), max(wb, 0.0)
    denom = wa + wb
    return (a * wa + b * wb) / denom


def greedy_merge(working: list[Working], merge_threshold: float) -> None:
    while len(working) >= 2:
        best = None  # (i, j, sim)
        for i in range(len(working)):
            for j in range(i + 1, len(working)):
                sim = cosine_similarity(working[i].centroid, working[j].centroid)
                if sim >= merge_threshold and (best is None or sim > best[2]):
                    best = (i, j, sim)
        if best is None:
            return
        i, j, _ = best
        cj = working.pop(j)
        wi = working[i]
        merged = weighted_mean(wi.centroid, wi.duration, cj.centroid, cj.duration)
        wi.centroid = l2_normalize(merged)
        if cj.duration > wi.duration:
            wi.rep = cj.rep
        wi.duration += cj.duration
        wi.members.extend(cj.members)


def merge_to_cap(working: list[Working], cap: int) -> None:
    while len(working) > cap and len(working) >= 2:
        best = None
        for i in range(len(working)):
            for j in range(i + 1, len(working)):
                sim = cosine_similarity(working[i].centroid, working[j].centroid)
                if best is None or sim > best[2]:
                    best = (i, j, sim)
        if best is None:
            return
        i, j, _ = best
        cj = working.pop(j)
        wi = working[i]
        merged = weighted_mean(wi.centroid, wi.duration, cj.centroid, cj.duration)
        wi.centroid = l2_normalize(merged)
        if cj.duration > wi.duration:
            wi.rep = cj.rep
        wi.duration += cj.duration
        wi.members.extend(cj.members)


def nearest_surviving(centroid: "np.ndarray", survivors: list[Working], min_cosine: float) -> int | None:
    best = None  # (i, sim)
    for i, w in enumerate(survivors):
        sim = cosine_similarity(centroid, w.centroid)
        if best is None or sim > best[1]:
            best = (i, sim)
    if best is not None and best[1] >= min_cosine:
        return best[0]
    return None


def postprocess(
    segments: list[Seg],
    clusters: list[ClusterIn],
    *,
    merge_threshold: float = DEFAULT_MERGE_THRESHOLD,
    floor_abs_secs: float = DEFAULT_FLOOR_ABS_SECS,
    floor_frac: float = DEFAULT_FLOOR_FRAC,
    reassign_min_cosine: float = DEFAULT_REASSIGN_MIN_COSINE,
    max_clusters: int | None = None,
    apply_merge: bool = True,
) -> PostProcessResult:
    """Faithful port of `postprocess::postprocess` in the Rust source."""
    if not clusters:
        return PostProcessResult(segments=list(segments), clusters=[])

    duration_by_key: dict[str, float] = {}
    for s in segments:
        d = max(s.end - s.start, 0.0)
        duration_by_key[s.speaker] = duration_by_key.get(s.speaker, 0.0) + d

    working = [
        Working(
            rep=c.speaker,
            centroid=c.centroid.copy(),
            duration=duration_by_key.get(c.speaker, 0.0),
            members=[c.speaker],
        )
        for c in clusters
    ]

    if apply_merge:
        greedy_merge(working, merge_threshold)

    total_speech = sum(w.duration for w in working)
    floor = max(floor_abs_secs, floor_frac * total_speech)

    survivors = [w for w in working if w.duration >= floor]
    dissolved = [w for w in working if w.duration < floor]

    if not survivors and dissolved:
        idx = max(range(len(dissolved)), key=lambda i: dissolved[i].duration)
        survivors = [dissolved.pop(idx)]

    if max_clusters is not None:
        cap = max(max_clusters, 1)
        merge_to_cap(survivors, cap)

    key_map: dict[str, str | None] = {}
    for w in survivors:
        for m in w.members:
            key_map[m] = w.rep

    for d in dissolved:
        target = nearest_surviving(d.centroid, survivors, reassign_min_cosine)
        mapped = survivors[target].rep if target is not None else None
        for m in d.members:
            key_map[m] = mapped

    out_segments = []
    for s in segments:
        mapped = key_map.get(s.speaker)
        if mapped is not None:
            out_segments.append(Seg(start=s.start, end=s.end, speaker=mapped))

    survivors.sort(key=lambda w: w.rep)
    out_clusters = [
        ClusterOut(speaker=w.rep, dim=len(w.centroid), centroid=w.centroid) for w in survivors
    ]

    return PostProcessResult(segments=out_segments, clusters=out_clusters)


def _load_diarize_response(path: str) -> tuple[list[Seg], list[ClusterIn]]:
    """Reads the sidecar's raw `{"type":"segments",...}` JSON response."""
    data = json.loads(open(path).read())
    segments = [Seg(start=s["start"], end=s["end"], speaker=s["speaker"]) for s in data["segments"]]
    clusters = [
        ClusterIn(speaker=c["speaker"], centroid=np.array(c["centroid"], dtype=np.float32))
        for c in data["clusters"]
    ]
    return segments, clusters


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="infile", required=True, help="raw sidecar diarize JSON response")
    ap.add_argument("--out", required=True, help="output RTTM path")
    ap.add_argument("--uri", required=True, help="RTTM <uri> field (meeting id)")
    ap.add_argument("--merge-threshold", type=float, default=DEFAULT_MERGE_THRESHOLD)
    ap.add_argument("--floor-abs-secs", type=float, default=DEFAULT_FLOOR_ABS_SECS)
    ap.add_argument("--floor-frac", type=float, default=DEFAULT_FLOOR_FRAC)
    ap.add_argument("--reassign-min-cosine", type=float, default=DEFAULT_REASSIGN_MIN_COSINE)
    ap.add_argument("--max-clusters", type=int, default=None)
    ap.add_argument(
        "--no-merge",
        action="store_true",
        help="skip step 1 (mirrors apply_merge=false, forced-K mode); the floor still runs",
    )
    args = ap.parse_args()

    segments, clusters = _load_diarize_response(args.infile)
    result = postprocess(
        segments,
        clusters,
        merge_threshold=args.merge_threshold,
        floor_abs_secs=args.floor_abs_secs,
        floor_frac=args.floor_frac,
        reassign_min_cosine=args.reassign_min_cosine,
        max_clusters=args.max_clusters,
        apply_merge=not args.no_merge,
    )

    lines = []
    for s in sorted(result.segments, key=lambda s: s.start):
        dur = s.end - s.start
        lines.append(f"SPEAKER {args.uri} 1 {s.start:.3f} {dur:.3f} <NA> <NA> {s.speaker} <NA> <NA>")
    with open(args.out, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))

    print(
        f"postmerge: {len(clusters)} raw clusters -> {len(result.clusters)} surviving "
        f"({len(segments)} -> {len(result.segments)} segments) -> {args.out}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
