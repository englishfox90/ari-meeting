#!/usr/bin/env python3
"""
Diarization threshold-calibration harness.

Mines labeled speaker data out of the Ari Meeting SQLite DB (speakers +
speaker_segments) and recommends empirical values for the re-ID matcher
thresholds in frontend/src-tauri/src/diarization/matching.rs
(`MatchConfig::auto_threshold` / `suggest_threshold` / `margin`), which today
are uncalibrated guesses (0.70 / 0.55 / 0.08).

Method
------
A "labeled person" is any `speakers` row with a non-NULL `person_id`
(i.e. the user has confirmed/assigned that voiceprint to a real person).
Every `speaker_segments` row whose `speaker_id` points at one of those
speakers carries a per-cluster embedding for that person, usually from a
different meeting each time.

  - SAME-person pairs: cosine similarity between two cluster embeddings
    that both belong to the SAME assigned person (ideally from different
    meetings — this is exactly the cross-meeting re-ID case the matcher
    has to get right).
  - DIFFERENT-person pairs: cosine similarity between cluster embeddings
    belonging to two DIFFERENT assigned persons.

The distributions of these two pair populations are the empirical ground
truth the matcher thresholds should be set against:
  - `auto_threshold`  <- p5 of the SAME-person distribution (floor 0.5):
    "how low does a genuine same-person match ever go, with 5% left in
    the tail" — auto-confirm should sit at/below that so we don't
    routinely miss real matches.
  - `suggest_threshold` <- equal-error-rate crossover of the two
    distributions (where P(same >= x) == P(different <= x)); the point
    at which false-accepts and false-rejects trade off evenly.
  - `margin` <- half the gap between the two distributions' medians,
    clamped to [0.05, 0.15].

This is a read-only reporting tool. It never writes to the DB (opens it
with SQLite URI mode=ro, and additionally immutable=1) and it never edits
matching.rs — a human updates MatchConfig by hand after reviewing output.

Usage
-----
    python3 tools/diarization_calibrate.py
    python3 tools/diarization_calibrate.py --db /path/to/meeting_minutes.sqlite
    python3 tools/diarization_calibrate.py --json

Requires: python3 stdlib + numpy.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import sys
from collections import defaultdict
from itertools import combinations

try:
    import numpy as np
except ImportError:
    print(
        "error: this tool requires numpy. Try:\n"
        "  uv run --with numpy tools/diarization_calibrate.py\n"
        "or: python3 -m pip install --user numpy",
        file=sys.stderr,
    )
    sys.exit(1)

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/com.meetily.ai/meeting_minutes.sqlite"
)

# Current MatchConfig defaults (frontend/src-tauri/src/diarization/matching.rs) — for comparison only.
CURRENT_AUTO_THRESHOLD = 0.70
CURRENT_SUGGEST_THRESHOLD = 0.55
CURRENT_MARGIN = 0.08

MIN_PERSONS_FOR_CONFIDENCE = 5
MIN_PAIRS_FOR_CONFIDENCE = 20


def open_readonly(db_path: str) -> sqlite3.Connection:
    """Open the DB strictly read-only; refuses to write even if asked to."""
    if not os.path.exists(db_path):
        raise FileNotFoundError(db_path)
    uri = f"file:{db_path}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    conn.execute("PRAGMA query_only = ON;")
    return conn


def blob_to_vec(blob: bytes) -> np.ndarray:
    """f32 little-endian bytes -> float32 numpy vector."""
    n = len(blob) // 4
    return np.array(struct.unpack(f"<{n}f", blob[: n * 4]), dtype=np.float32)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def load_labeled_embeddings(conn: sqlite3.Connection):
    """
    Returns dict[(embedding_model, dim)] -> dict[person_id] -> list[(meeting_id, np.ndarray)]
    drawn from speaker_segments joined to assigned (person_id NOT NULL) speakers.
    """
    rows = conn.execute(
        """
        SELECT s.person_id, s.embedding_model, s.dim, ss.meeting_id, ss.embedding
        FROM speaker_segments ss
        JOIN speakers s ON ss.speaker_id = s.id
        WHERE s.person_id IS NOT NULL AND ss.embedding IS NOT NULL
        """
    ).fetchall()

    by_group: dict[tuple, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for person_id, model, dim, meeting_id, emb_blob in rows:
        vec = blob_to_vec(emb_blob)
        if vec.size == 0:
            continue
        by_group[(model, dim)][person_id].append((meeting_id, vec))
    return by_group


def build_pairs(persons: dict):
    """
    persons: dict[person_id] -> list[(meeting_id, vec)]
    Returns (same_sims, diff_sims, n_persons_with_2plus, n_persons_total)
    same_sims prefers cross-meeting pairs but falls back to within-meeting
    pairs if a person only has one meeting's worth of clusters.
    """
    same_sims: list[float] = []
    diff_sims: list[float] = []

    person_ids = list(persons.keys())

    # Same-person pairs.
    for pid, items in persons.items():
        if len(items) < 2:
            continue
        cross_meeting_pairs = [
            (v1, v2)
            for (m1, v1), (m2, v2) in combinations(items, 2)
            if m1 != m2
        ]
        pairs_to_use = cross_meeting_pairs if cross_meeting_pairs else list(
            combinations([v for _, v in items], 2)
        )
        for v1, v2 in pairs_to_use:
            same_sims.append(cosine(v1, v2))

    # Different-person pairs: one representative-ish sampling — all cross pairs
    # between every embedding of person A and every embedding of person B.
    for pid_a, pid_b in combinations(person_ids, 2):
        for _, va in persons[pid_a]:
            for _, vb in persons[pid_b]:
                diff_sims.append(cosine(va, vb))

    n_with_2plus = sum(1 for items in persons.values() if len(items) >= 2)
    return same_sims, diff_sims, n_with_2plus, len(person_ids)


def intra_person_consistency(persons: dict):
    """mean intra-person pairwise cosine per person; flags < 0.5 as suspect."""
    out = {}
    for pid, items in persons.items():
        if len(items) < 2:
            out[pid] = (None, len(items))
            continue
        sims = [cosine(v1, v2) for (_, v1), (_, v2) in combinations(items, 2)]
        out[pid] = (float(np.mean(sims)), len(items))
    return out


def pct(values, p):
    if not values:
        return float("nan")
    return float(np.percentile(np.array(values), p))


def equal_error_crossover(same: list, diff: list):
    """
    Sweep thresholds; find x minimizing |P(same >= x) - P(diff <= x)|
    i.e. the equal-error-rate point between "false reject of a real match"
    and "false accept of a different person".
    """
    if not same or not diff:
        return None
    same_arr = np.array(same)
    diff_arr = np.array(diff)
    candidates = np.linspace(0.0, 1.0, 2001)
    best_x = None
    best_gap = float("inf")
    for x in candidates:
        far = float(np.mean(diff_arr >= x))  # false accept rate at threshold x
        frr = float(np.mean(same_arr < x))  # false reject rate at threshold x
        gap = abs(far - frr)
        if gap < best_gap:
            best_gap = gap
            best_x = float(x)
    return best_x


def ascii_hist(values, label, width=50, bins=20):
    if not values:
        return f"  ({label}: no data)"
    arr = np.array(values)
    counts, edges = np.histogram(arr, bins=bins, range=(0.0, 1.0))
    max_count = counts.max() if counts.max() > 0 else 1
    lines = [f"  {label} (n={len(values)}):"]
    for c, lo, hi in zip(counts, edges[:-1], edges[1:]):
        bar_len = int(round((c / max_count) * width))
        bar = "#" * bar_len
        lines.append(f"    {lo:0.2f}-{hi:0.2f} | {bar} {c}")
    return "\n".join(lines)


def summarize_distribution(values):
    if not values:
        return None
    arr = np.array(values)
    return {
        "n": len(values),
        "mean": float(np.mean(arr)),
        "median": float(np.median(arr)),
        "p5": pct(values, 5),
        "p95": pct(values, 95),
        "min": float(np.min(arr)),
        "max": float(np.max(arr)),
    }


def recommend_thresholds(same_sims, diff_sims):
    same_summary = summarize_distribution(same_sims)
    diff_summary = summarize_distribution(diff_sims)

    if same_summary is None:
        return None

    auto = max(same_summary["p5"], 0.5)

    crossover = equal_error_crossover(same_sims, diff_sims) if diff_sims else None
    if crossover is not None:
        suggest = crossover
    else:
        # No different-person data at all — fall back to a conservative
        # offset below auto so Suggest still means something.
        suggest = max(auto - 0.15, 0.3)

    if diff_summary is not None:
        gap = same_summary["median"] - diff_summary["median"]
        margin = max(0.05, min(0.15, gap / 2.0))
    else:
        margin = CURRENT_MARGIN

    # Keep suggest strictly below auto.
    if suggest >= auto:
        suggest = max(auto - 0.05, 0.3)

    return {
        "auto_threshold": round(auto, 4),
        "suggest_threshold": round(suggest, 4),
        "margin": round(margin, 4),
    }


def analyze_group(model: str, dim: int, persons: dict, args):
    same_sims, diff_sims, n_2plus, n_total = build_pairs(persons)
    n_pairs_total = len(same_sims) + len(diff_sims)

    low_confidence = (
        n_total < MIN_PERSONS_FOR_CONFIDENCE or n_pairs_total < MIN_PAIRS_FOR_CONFIDENCE
    )

    same_summary = summarize_distribution(same_sims)
    diff_summary = summarize_distribution(diff_sims)
    recommendation = recommend_thresholds(same_sims, diff_sims)

    consistency = intra_person_consistency(persons)
    suspect = {
        pid: score
        for pid, (score, n) in consistency.items()
        if score is not None and score < 0.5
    }

    result = {
        "embedding_model": model,
        "dim": dim,
        "labeled_persons": n_total,
        "persons_with_2plus_clusters": n_2plus,
        "same_person_pairs": len(same_sims),
        "different_person_pairs": len(diff_sims),
        "low_confidence": low_confidence,
        "same_distribution": same_summary,
        "different_distribution": diff_summary,
        "recommendation": recommendation,
        "current_config": {
            "auto_threshold": CURRENT_AUTO_THRESHOLD,
            "suggest_threshold": CURRENT_SUGGEST_THRESHOLD,
            "margin": CURRENT_MARGIN,
        },
        "suspect_low_consistency_persons": suspect,
        "person_consistency": {
            pid: {"mean_intra_cosine": score, "n_clusters": n}
            for pid, (score, n) in consistency.items()
        },
    }

    if not args.json:
        print(f"\n=== embedding_model={model} dim={dim} ===")
        print(f"labeled persons: {n_total} ({n_2plus} with >=2 clusters)")
        print(f"same-person pairs: {len(same_sims)}   different-person pairs: {len(diff_sims)}")
        if low_confidence:
            print(
                "\n*** LOW CONFIDENCE: fewer than "
                f"{MIN_PERSONS_FOR_CONFIDENCE} labeled persons or "
                f"{MIN_PAIRS_FOR_CONFIDENCE} total pairs. Treat results as "
                "directional only — keep collecting assignments and re-run. ***"
            )

        def fmt_summary(s):
            if s is None:
                return "  (no data)"
            return (
                f"  n={s['n']}  mean={s['mean']:.3f}  median={s['median']:.3f}  "
                f"p5={s['p5']:.3f}  p95={s['p95']:.3f}  range=[{s['min']:.3f}, {s['max']:.3f}]"
            )

        print("\nSame-person cosine similarity:")
        print(fmt_summary(same_summary))
        print("\nDifferent-person cosine similarity:")
        print(fmt_summary(diff_summary))

        if same_summary and diff_summary:
            overlap_lo = diff_summary["p5"]
            overlap_hi = same_summary["p95"]
            if overlap_hi > overlap_lo:
                print(
                    f"\nOverlap region (same p95 vs different p5): "
                    f"[{overlap_lo:.3f}, {overlap_hi:.3f}] "
                    f"(width={overlap_hi - overlap_lo:.3f})"
                )
            else:
                print("\nOverlap region: none observed (distributions cleanly separated)")

        print("\n" + ascii_hist(same_sims, "same-person"))
        print(ascii_hist(diff_sims, "different-person"))

        if recommendation:
            print("\n--- Recommended MatchConfig (frontend/src-tauri/src/diarization/matching.rs) ---")
            print(f"  auto_threshold:    {recommendation['auto_threshold']}  (current: {CURRENT_AUTO_THRESHOLD})")
            print(f"  suggest_threshold: {recommendation['suggest_threshold']}  (current: {CURRENT_SUGGEST_THRESHOLD})")
            print(f"  margin:            {recommendation['margin']}  (current: {CURRENT_MARGIN})")
            print("\n  diarization-tuning.json-style summary:")
            print(
                json.dumps(
                    {
                        "embedding_model": model,
                        "dim": dim,
                        "auto_threshold": recommendation["auto_threshold"],
                        "suggest_threshold": recommendation["suggest_threshold"],
                        "margin": recommendation["margin"],
                        "n_labeled_persons": n_total,
                        "n_same_pairs": len(same_sims),
                        "n_different_pairs": len(diff_sims),
                        "low_confidence": low_confidence,
                    },
                    indent=2,
                )
            )

        if suspect:
            print("\n*** Suspect enrollments (mean intra-person cosine < 0.5) ***")
            for pid, score in suspect.items():
                n = consistency[pid][1]
                print(f"  person_id={pid}  mean_intra_cosine={score:.3f}  n_clusters={n}")
            print(
                "  These persons' assigned clusters don't agree well with each other —"
                " possible mis-assignment. Consider reviewing in the app."
            )
        else:
            print("\nNo suspect low-consistency enrollments detected.")

    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB, help="path to meeting_minutes.sqlite")
    parser.add_argument("--json", action="store_true", help="machine-readable JSON output")
    args = parser.parse_args()

    try:
        conn = open_readonly(args.db)
    except FileNotFoundError:
        msg = f"error: DB not found at {args.db}"
        if args.json:
            print(json.dumps({"error": msg}))
        else:
            print(msg, file=sys.stderr)
        sys.exit(1)

    try:
        by_group = load_labeled_embeddings(conn)
    finally:
        conn.close()

    if not by_group:
        msg = (
            "No labeled speaker data yet (no speakers with person_id assigned, "
            "or no speaker_segments embeddings for them). Assign a few more "
            "speakers to persons in the app, then re-run this tool."
        )
        if args.json:
            print(json.dumps({"error": msg, "groups": []}))
        else:
            print(msg)
        return

    results = []
    for (model, dim), persons in by_group.items():
        results.append(analyze_group(model, dim, persons, args))

    if args.json:
        print(json.dumps({"groups": results}, indent=2))


if __name__ == "__main__":
    main()
