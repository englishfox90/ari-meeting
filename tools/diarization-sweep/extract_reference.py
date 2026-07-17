#!/usr/bin/env python3
"""
Extract reference RTTM files (ground truth for the S3 parity rig) from the
Ari Meeting app's SQLite DB.

## Ground-truth model (decided 2026-07-16, see repo CLAUDE.md / PRD S3 spike)

This is a **parity-vs-current-shipping** test, not an absolute-DER-vs-human-
labels test. The "reference" is the verified-correct CURRENT APP diarization
output (sherpa-onnx + the app's post-processing), taken per-transcript-row
from the DB after a human (Paul) has confirmed the speaker labels are right.
It answers: "does a candidate engine (today: the current sherpa recipe itself,
as a rig-validation check; later: FluidAudio) match what we already ship and
trust?" — not "is this diarization objectively correct against a human-
transcribed corpus."

Per-segment reference labels come from `transcripts`:
    audio_start_time (REAL sec), audio_end_time (REAL sec), speaker_id

Speaker naming for the RTTM label (DER only cares about the label PARTITION,
not the string, so this is for readability):
    transcripts.speaker_id -> speakers.person_id -> persons.display_name
    fallback: speakers.label
    fallback: the raw speaker_id

This is a READ-ONLY tool. It opens the DB with `mode=ro&immutable=1` in the
SQLite URI AND sets `PRAGMA query_only = ON` (mirrors tools/diarization_calibrate.py)
so a write anywhere in this codepath fails loudly instead of corrupting the
app's live database.

## Output

- `references/<meeting-id>.rttm` — standard RTTM, one line per transcript
  segment:
      SPEAKER <uri> <channel> <start> <duration> <NA> <NA> <speaker-label> <NA> <NA>
- `references/manifest.json` — the reference-set catalog: meeting id, title,
  number of distinct speakers, duration (seconds), audio path, and a
  `verified: true|false` flag. Only the seed meeting (Adhoc with Nia) is
  `verified: true` today; the manifest lists the other labeled meetings as
  `verified: false` candidates awaiting Paul's confirmation before they count
  toward the S3 verdict.

RTTM contains only timings + opaque labels — no transcript text — so it is
safe to commit (references/*.rttm + manifest.json ARE the committed
artifacts; work/, hypotheses/, results/ are gitignored).

## Usage

    uv run --with numpy python3 extract_reference.py --meeting meeting-d894f3ce-2ffa-4b34-bba6-1265804df866
    uv run --with numpy python3 extract_reference.py --all
    uv run --with numpy python3 extract_reference.py --all --db /path/to/meeting_minutes.sqlite
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/com.meetily.ai/meeting_minutes.sqlite"
)

HERE = Path(__file__).resolve().parent
REFERENCES_DIR = HERE / "references"

# The only meeting Paul has explicitly confirmed as correct (2026-07-16).
# See the S3 kickoff instructions: 2 speakers, ~10 min, auto-diarized, verified.
VERIFIED_MEETING_IDS = {"meeting-d894f3ce-2ffa-4b34-bba6-1265804df866"}


def open_readonly(db_path: str) -> sqlite3.Connection:
    """Open the DB strictly read-only; refuses to write even if asked to."""
    if not os.path.exists(db_path):
        raise FileNotFoundError(db_path)
    uri = f"file:{db_path}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    conn.execute("PRAGMA query_only = ON;")
    return conn


def assert_readonly(conn: sqlite3.Connection) -> None:
    """Sanity check: a write MUST fail on this connection."""
    try:
        conn.execute("CREATE TABLE __rw_probe__ (x INTEGER);")
    except sqlite3.OperationalError:
        return
    else:
        # If it somehow succeeded, roll it back and refuse to proceed.
        conn.execute("DROP TABLE IF EXISTS __rw_probe__;")
        raise RuntimeError(
            "DB connection is NOT read-only (write probe succeeded) — refusing to continue"
        )


def list_meetings(conn: sqlite3.Connection) -> list[dict]:
    rows = conn.execute(
        "SELECT id, title, folder_path FROM meetings ORDER BY created_at"
    ).fetchall()
    return [{"id": r[0], "title": r[1], "folder_path": r[2]} for r in rows]


def speaker_label_map(conn: sqlite3.Connection) -> dict[str, str]:
    """speaker_id -> display label (person display_name > speakers.label > speaker_id)."""
    rows = conn.execute(
        """
        SELECT s.id, s.label, p.display_name
        FROM speakers s
        LEFT JOIN persons p ON s.person_id = p.id
        """
    ).fetchall()
    out: dict[str, str] = {}
    for speaker_id, label, display_name in rows:
        name = display_name or label or speaker_id
        # RTTM fields are whitespace-delimited; collapse whitespace defensively.
        out[speaker_id] = str(name).replace(" ", "_")
    return out


def extract_segments(conn: sqlite3.Connection, meeting_id: str) -> list[tuple[float, float, str]]:
    """Returns list of (start, end, speaker_id) ordered by start time. Skips
    rows with NULL speaker_id or NULL/negative-duration timing (nothing to
    label; not fabricating a speaker for them)."""
    rows = conn.execute(
        """
        SELECT audio_start_time, audio_end_time, speaker_id
        FROM transcripts
        WHERE meeting_id = ?
        ORDER BY audio_start_time
        """,
        (meeting_id,),
    ).fetchall()

    segments = []
    for start, end, speaker_id in rows:
        if speaker_id is None or start is None or end is None:
            continue
        if end <= start:
            continue
        segments.append((float(start), float(end), speaker_id))
    return segments


def write_rttm(path: Path, meeting_id: str, segments: list[tuple[float, float, str]], labels: dict[str, str]) -> None:
    lines = []
    for start, end, speaker_id in segments:
        dur = end - start
        label = labels.get(speaker_id, speaker_id)
        lines.append(
            f"SPEAKER {meeting_id} 1 {start:.3f} {dur:.3f} <NA> <NA> {label} <NA> <NA>"
        )
    path.write_text("\n".join(lines) + ("\n" if lines else ""))


def build_manifest_entry(
    conn: sqlite3.Connection,
    meeting: dict,
    segments: list[tuple[float, float, str]],
) -> dict:
    distinct_speakers = sorted({s for _, _, s in segments})
    duration = max((end for _, end, _ in segments), default=0.0)
    audio_path = None
    if meeting["folder_path"]:
        candidate = Path(meeting["folder_path"]) / "audio.mp4"
        audio_path = str(candidate)
    return {
        "meeting_id": meeting["id"],
        "title": meeting["title"],
        "num_speakers": len(distinct_speakers),
        "num_segments": len(segments),
        "duration_secs": round(duration, 2),
        "audio_path": audio_path,
        "rttm": f"references/{meeting['id']}.rttm",
        "verified": meeting["id"] in VERIFIED_MEETING_IDS,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=DEFAULT_DB, help="path to meeting_minutes.sqlite")
    ap.add_argument("--meeting", help="extract a single meeting id")
    ap.add_argument("--all", action="store_true", help="extract every meeting with folder_path + transcript rows")
    ap.add_argument("--out", default=str(REFERENCES_DIR), help="output directory for references/")
    args = ap.parse_args()

    if not args.meeting and not args.all:
        ap.error("pass --meeting <id> or --all")

    conn = open_readonly(args.db)
    assert_readonly(conn)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    meetings = list_meetings(conn)
    if args.meeting:
        meetings = [m for m in meetings if m["id"] == args.meeting]
        if not meetings:
            print(f"error: meeting {args.meeting!r} not found in DB", file=sys.stderr)
            return 1

    labels = speaker_label_map(conn)

    manifest_entries = []
    for m in meetings:
        segments = extract_segments(conn, m["id"])
        if not segments:
            print(f"skip {m['id']} ({m['title']!r}): no labeled transcript segments", file=sys.stderr)
            continue
        rttm_path = out_dir / f"{m['id']}.rttm"
        write_rttm(rttm_path, m["id"], segments, labels)
        entry = build_manifest_entry(conn, m, segments)
        manifest_entries.append(entry)
        flag = "VERIFIED" if entry["verified"] else "unverified"
        print(
            f"[{flag}] {m['id']}  {m['title']!r}  "
            f"speakers={entry['num_speakers']} segments={entry['num_segments']} "
            f"duration={entry['duration_secs']:.1f}s -> {rttm_path}"
        )

    manifest_path = out_dir / "manifest.json"
    # Merge with any existing manifest (e.g. re-running --meeting for one entry
    # shouldn't drop the others already extracted via --all).
    existing: dict[str, dict] = {}
    if manifest_path.exists():
        try:
            prior = json.loads(manifest_path.read_text())
            for e in prior.get("meetings", []):
                existing[e["meeting_id"]] = e
        except (json.JSONDecodeError, KeyError):
            pass
    for e in manifest_entries:
        existing[e["meeting_id"]] = e

    manifest = {
        "note": (
            "Parity-vs-current-shipping reference set (see README). Only "
            "entries with verified:true have been human-confirmed correct; "
            "the rest are unverified candidates awaiting confirmation before "
            "they count toward the S3 verdict."
        ),
        "meetings": sorted(existing.values(), key=lambda e: e["meeting_id"]),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"\nwrote {manifest_path} ({len(existing)} meeting(s) in manifest)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
