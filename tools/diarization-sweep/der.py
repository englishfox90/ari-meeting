#!/usr/bin/env python3
"""
Score hypothesis RTTMs against reference RTTMs with Diarization Error Rate
(DER), using `pyannote.metrics` (preferred) with a from-scratch fallback.

## Usage

    # Score one engine/label's hypothesis set against the reference manifest:
    uv run --with pyannote.metrics --with numpy python3 der.py \\
        --engine sherpa --label ct0.9_mt0.7

    # Score a future FluidAudio RTTM set the same way (see README "Adding
    # FluidAudio (S3)"):
    uv run --with pyannote.metrics --with numpy python3 der.py \\
        --engine fluidaudio --label v1

Writes `results/<engine>-<label>.json` and prints a per-meeting + mean table.
Reports BOTH the standard 0.25s-collar DER and the strict no-collar DER.

## RTTM parsing

Standard RTTM: `SPEAKER <uri> <channel> <start> <duration> <NA> <NA> <label> <NA> <NA>`.
Only the `SPEAKER` line type is used (no `SPKR-INFO`/overlap lines in this
recipe's output). DER cares about the label PARTITION, not the string, so
hypothesis and reference speaker-label vocabularies need not match — the
optimal one-to-one mapping is computed internally (by pyannote.metrics, or
by the Hungarian-algorithm fallback below).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCES_DIR = HERE / "references"
HYPOTHESES_DIR = HERE / "hypotheses"
RESULTS_DIR = HERE / "results"


def parse_rttm(path: Path) -> list[tuple[float, float, str]]:
    """Returns list of (start, end, label), SPEAKER lines only."""
    out = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if not parts or parts[0] != "SPEAKER":
            continue
        start = float(parts[3])
        dur = float(parts[4])
        label = parts[7]
        out.append((start, start + dur, label))
    return out


def _try_pyannote():
    try:
        from pyannote.core import Annotation, Segment
        from pyannote.metrics.diarization import DiarizationErrorRate
        return Annotation, Segment, DiarizationErrorRate
    except ImportError:
        return None


def _annotation_from_rttm(Annotation, Segment, segs: list[tuple[float, float, str]]):
    ann = Annotation()
    for start, end, label in segs:
        if end <= start:
            continue
        ann[Segment(start, end)] = label
    return ann


def der_pyannote(ref_segs, hyp_segs, collar: float) -> dict:
    Annotation, Segment, DiarizationErrorRate = _try_pyannote()
    ref = _annotation_from_rttm(Annotation, Segment, ref_segs)
    hyp = _annotation_from_rttm(Annotation, Segment, hyp_segs)
    metric = DiarizationErrorRate(collar=collar, skip_overlap=False)
    components = metric(ref, hyp, detailed=True)
    der = components["diarization error rate"]
    return {
        "der": der,
        "false_alarm": components.get("false alarm"),
        "missed_detection": components.get("missed detection"),
        "confusion": components.get("confusion"),
        "total": components.get("total"),
        "backend": "pyannote.metrics",
    }


# ---------------------------------------------------------------------------
# Fallback: manual DER (Hungarian optimal speaker mapping), used only if
# pyannote.metrics is unavailable in the environment. No collar support (the
# collar-free number is directly comparable to pyannote's collar=0.0 mode).
# ---------------------------------------------------------------------------

def _timeline_events(segs: list[tuple[float, float, str]]) -> list[float]:
    pts = set()
    for s, e, _ in segs:
        pts.add(s)
        pts.add(e)
    return sorted(pts)


def _label_at(segs: list[tuple[float, float, str]], t_mid: float) -> set[str]:
    return {label for s, e, label in segs if s <= t_mid < e}


def der_manual(ref_segs, hyp_segs) -> dict:
    """A simple, correct (no-collar, no-overlap-credit) DER: builds a common
    fine-grained timeline, buckets time by (ref-labels-present, hyp-labels-present)
    at each interval midpoint, finds the optimal ref<->hyp label mapping via the
    Hungarian algorithm on total overlap duration, then sums missed/false-alarm/
    confusion time over the reference speech duration.
    """
    import numpy as np
    from scipy.optimize import linear_sum_assignment

    ref_labels = sorted({label for _, _, label in ref_segs})
    hyp_labels = sorted({label for _, _, label in hyp_segs})

    points = sorted(set(_timeline_events(ref_segs)) | set(_timeline_events(hyp_segs)))
    if len(points) < 2:
        return {"der": 0.0, "false_alarm": 0.0, "missed_detection": 0.0, "confusion": 0.0, "total": 0.0, "backend": "manual-fallback"}

    # Overlap matrix (ref_label x hyp_label) in seconds, for optimal mapping.
    overlap = np.zeros((len(ref_labels), len(hyp_labels)))
    ref_idx = {l: i for i, l in enumerate(ref_labels)}
    hyp_idx = {l: i for i, l in enumerate(hyp_labels)}

    total_ref_speech = 0.0
    false_alarm = 0.0
    missed = 0.0

    for a, b in zip(points[:-1], points[1:]):
        dur = b - a
        if dur <= 0:
            continue
        mid = (a + b) / 2.0
        r = _label_at(ref_segs, mid)
        h = _label_at(hyp_segs, mid)
        if r:
            total_ref_speech += dur
        if not r and h:
            false_alarm += dur
        if r and not h:
            missed += dur
        for rl in r:
            for hl in h:
                overlap[ref_idx[rl], hyp_idx[hl]] += dur

    # Optimal one-to-one mapping maximizing total mapped overlap.
    confusion = 0.0
    if ref_labels and hyp_labels:
        cost = -overlap  # maximize overlap == minimize -overlap
        row_ind, col_ind = linear_sum_assignment(cost)
        mapped_pairs = {(ref_labels[r], hyp_labels[c]) for r, c in zip(row_ind, col_ind)}
    else:
        mapped_pairs = set()

    for a, b in zip(points[:-1], points[1:]):
        dur = b - a
        if dur <= 0:
            continue
        mid = (a + b) / 2.0
        r = _label_at(ref_segs, mid)
        h = _label_at(hyp_segs, mid)
        if not r or not h:
            continue
        # For single-speaker-per-instant segments (the common case here), r and h
        # are each size <=1. If the (ref,hyp) pair isn't in the optimal mapping,
        # it's a confusion (wrong speaker assigned).
        if not any((rl, hl) in mapped_pairs for rl in r for hl in h):
            confusion += dur

    total = total_ref_speech if total_ref_speech > 0 else 1.0
    der = (false_alarm + missed + confusion) / total
    return {
        "der": der,
        "false_alarm": false_alarm,
        "missed_detection": missed,
        "confusion": confusion,
        "total": total_ref_speech,
        "backend": "manual-fallback",
    }


def score_meeting(ref_path: Path, hyp_path: Path) -> dict:
    ref_segs = parse_rttm(ref_path)
    hyp_segs = parse_rttm(hyp_path)

    result = {}
    if _try_pyannote():
        result["collar_0.25"] = der_pyannote(ref_segs, hyp_segs, collar=0.25)
        result["collar_0.0"] = der_pyannote(ref_segs, hyp_segs, collar=0.0)
    else:
        print("warning: pyannote.metrics not available, using manual fallback (no collar support)", file=sys.stderr)
        m = der_manual(ref_segs, hyp_segs)
        result["collar_0.0"] = m
        result["collar_0.25"] = None
    result["stamp_accuracy"] = stamp_accuracy(ref_segs, hyp_segs)
    return result


# ---------------------------------------------------------------------------
# Transcript-stamping accuracy — a second, arguably more operationally
# relevant metric alongside DER.
#
# Standard DER penalizes false-alarm/missed-detection from ANY boundary
# mismatch between reference and hypothesis segments. But the reference RTTM
# here is built from TRANSCRIPT segment boundaries (Parakeet/Whisper VAD),
# while a from-scratch sherpa diarization run does its OWN independent VAD
# (the pyannote segmentation model) — its segment boundaries never line up
# exactly with the transcript's, even when the SPEAKER LABEL is completely
# correct. That boundary noise shows up in DER as false-alarm/missed-detection
# and can dominate the number even for a faithful, correctly-labeled run.
#
# What the app actually does downstream (`stamp_transcripts` in
# `frontend/src-tauri/src/diarization/commands.rs`) is NOT "adopt the
# diarizer's boundaries" — it stamps each EXISTING transcript row with
# whichever diarization segment it most overlaps in time. That is the
# operationally-relevant question for parity: "would this diarization run
# assign the same speaker to each transcript line as the verified reference
# did?" `stamp_accuracy` answers exactly that, mirroring the app's own
# overlap-assignment logic, so it isn't confounded by VAD-boundary drift.
# ---------------------------------------------------------------------------

def stamp_accuracy(ref_segs, hyp_segs) -> dict:
    import numpy as np
    from scipy.optimize import linear_sum_assignment

    if not ref_segs or not hyp_segs:
        return {"accuracy": None, "note": "empty ref or hyp segments"}

    ref_labels = sorted({label for _, _, label in ref_segs})
    hyp_labels = sorted({label for _, _, label in hyp_segs})
    ref_idx = {l: i for i, l in enumerate(ref_labels)}
    hyp_idx = {l: i for i, l in enumerate(hyp_labels)}

    # For each reference (transcript) segment, find the hypothesis segment it
    # most overlaps — mirrors stamp_transcripts' "greatest overlap wins" rule.
    contingency = np.zeros((len(ref_labels), len(hyp_labels)))
    total_dur = 0.0
    unmatched_dur = 0.0
    for r_start, r_end, r_label in ref_segs:
        dur = r_end - r_start
        if dur <= 0:
            continue
        total_dur += dur
        best = None  # (overlap, hyp_label)
        for h_start, h_end, h_label in hyp_segs:
            overlap = min(r_end, h_end) - max(r_start, h_start)
            if overlap <= 0:
                continue
            if best is None or overlap > best[0]:
                best = (overlap, h_label)
        if best is None:
            unmatched_dur += dur
            continue
        contingency[ref_idx[r_label], hyp_idx[best[1]]] += dur

    if total_dur <= 0:
        return {"accuracy": None, "note": "zero total reference duration"}

    row_ind, col_ind = linear_sum_assignment(-contingency)
    matched_dur = float(contingency[row_ind, col_ind].sum())

    return {
        "accuracy": matched_dur / total_dur,
        "matched_secs": matched_dur,
        "unmatched_secs": unmatched_dur,
        "total_secs": total_dur,
        "n_ref_labels": len(ref_labels),
        "n_hyp_labels": len(hyp_labels),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", required=True, help='e.g. "sherpa" or "fluidaudio"')
    ap.add_argument("--label", required=True, help='parameter/version label, e.g. "ct0.9_mt0.7" or "v1"')
    ap.add_argument("--verified-only", action="store_true", default=True,
                    help="score only manifest entries with verified:true (default: on)")
    ap.add_argument("--include-unverified", dest="verified_only", action="store_false",
                    help="also score unverified manifest entries (informational only)")
    ap.add_argument("--references", default=str(REFERENCES_DIR))
    ap.add_argument("--hypotheses", default=str(HYPOTHESES_DIR))
    ap.add_argument("--results", default=str(RESULTS_DIR))
    args = ap.parse_args()

    references_dir = Path(args.references)
    manifest_path = references_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"error: no manifest at {manifest_path} — run extract_reference.py first", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())["meetings"]

    hyp_dir = Path(args.hypotheses) / args.engine / args.label
    if not hyp_dir.exists():
        print(f"error: no hypothesis dir at {hyp_dir} — run run_sweep.py (or drop in FluidAudio output) first", file=sys.stderr)
        return 1

    meetings = [m for m in manifest if (not args.verified_only) or m["verified"]]
    if not meetings:
        print("error: no meetings match (verified-only and nothing verified yet?)", file=sys.stderr)
        return 1

    per_meeting = {}
    for m in meetings:
        meeting_id = m["meeting_id"]
        ref_path = references_dir / f"{meeting_id}.rttm"
        hyp_path = hyp_dir / f"{meeting_id}.rttm"
        if not ref_path.exists():
            print(f"skip {meeting_id}: no reference RTTM at {ref_path}", file=sys.stderr)
            continue
        if not hyp_path.exists():
            print(f"skip {meeting_id}: no hypothesis RTTM at {hyp_path}", file=sys.stderr)
            continue
        per_meeting[meeting_id] = {"title": m["title"], **score_meeting(ref_path, hyp_path)}

    if not per_meeting:
        print("error: nothing scored (no ref/hyp RTTM pairs found)", file=sys.stderr)
        return 1

    def mean_der(collar_key: str) -> float | None:
        vals = [v[collar_key]["der"] for v in per_meeting.values() if v.get(collar_key)]
        return sum(vals) / len(vals) if vals else None

    def mean_stamp_acc() -> float | None:
        vals = [v["stamp_accuracy"]["accuracy"] for v in per_meeting.values() if v.get("stamp_accuracy", {}).get("accuracy") is not None]
        return sum(vals) / len(vals) if vals else None

    summary = {
        "engine": args.engine,
        "label": args.label,
        "verified_only": args.verified_only,
        "n_meetings": len(per_meeting),
        "mean_der_collar_0.25": mean_der("collar_0.25"),
        "mean_der_collar_0.0": mean_der("collar_0.0"),
        "mean_stamp_accuracy": mean_stamp_acc(),
        "per_meeting": per_meeting,
    }

    RESULTS_DIR_p = Path(args.results)
    RESULTS_DIR_p.mkdir(parents=True, exist_ok=True)
    out_path = RESULTS_DIR_p / f"{args.engine}-{args.label}.json"
    out_path.write_text(json.dumps(summary, indent=2, default=lambda o: None) + "\n")

    print(f"\n{'meeting':<45} {'DER(collar=0.25)':>18} {'DER(collar=0.0)':>18} {'stamp_acc':>10}")
    for meeting_id, v in per_meeting.items():
        c25 = v["collar_0.25"]["der"] if v.get("collar_0.25") else float("nan")
        c0 = v["collar_0.0"]["der"] if v.get("collar_0.0") else float("nan")
        acc = v["stamp_accuracy"]["accuracy"]
        acc_s = f"{acc:.4f}" if acc is not None else "n/a"
        print(f"{meeting_id:<45} {c25:>18.4f} {c0:>18.4f} {acc_s:>10}")
    mean_acc = summary["mean_stamp_accuracy"]
    mean_acc_s = f"{mean_acc:.4f}" if mean_acc is not None else "n/a"
    print(f"{'MEAN':<45} {summary['mean_der_collar_0.25'] or float('nan'):>18.4f} {summary['mean_der_collar_0.0'] or float('nan'):>18.4f} {mean_acc_s:>10}")
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
