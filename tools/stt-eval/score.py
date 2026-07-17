#!/usr/bin/env python3
"""
score.py — S2 STT-eval scoring harness.

Compares three hypotheses per meeting:
  - SpeechAnalyzer / SpeechTranscriber module   (sa_transcriber)
  - SpeechAnalyzer / DictationTranscriber module (sa_dictation)
  - Parakeet (the shipped production transcript, read from the app DB)

against a Whisper-large-v3 (mlx-whisper) transcription used as a
COMPARATIVE PSEUDO-GOLD reference, NOT absolute truth (Whisper itself makes
errors — this is a tie-breaker among three real systems, not ground truth).

Computes, per meeting and aggregate:
  - core WER (lowercase, punctuation stripped) of each hypothesis vs reference
  - punctuation-preserving WER (lowercase, punctuation KEPT) vs reference
  - direct SpeechAnalyzer <-> Parakeet agreement (core WER, no reference needed)
  - punctuation/casing presence (counts) per hypothesis
  - word-timestamp coverage (SpeechAnalyzer only; Parakeet has segment-level
    timestamps only, no word-level, called out explicitly)
  - runtime (wall_ms) per model per meeting, where available

Emits results/comparison.json + results/COMPARISON.md, and for the
worst-agreement meeting, disagreements/<meeting>.md with aligned snippets.

Run with: uv run --with jiwer python3 score.py
"""
import json
import re
import string
import sys
from pathlib import Path
from difflib import SequenceMatcher

import jiwer

ROOT = Path(__file__).parent
RESULTS = ROOT / "results"
DISAGREEMENTS = RESULTS / "disagreements"
SA_OUT = RESULTS / "speechanalyzer"
WHISPER_OUT = RESULTS / "reference"
PARAKEET_OUT = RESULTS / "parakeet"

MEETINGS = ["nia", "career_1on1", "metro2", "servicing_org", "brian1on1"]
LABELS = {
    "nia": "Adhoc with Nia (short, clean 1:1, ~10min)",
    "career_1on1": "1:1 Check-in & Career Development (~23min)",
    "metro2": "Metro2 (~43min)",
    "servicing_org": "Servicing Organization Strategy Review (~78min, 7 speakers)",
    "brian1on1": "Brian 1:1 (~80min, longest)",
}

PUNCT_RE = re.compile(r"[^\w\s']", re.UNICODE)


def normalize(text, keep_punct=False):
    text = text.strip()
    if not keep_punct:
        text = PUNCT_RE.sub(" ", text)
    text = text.lower()
    text = re.sub(r"\s+", " ", text).strip()
    return text


def wer(ref_text, hyp_text, keep_punct=False):
    ref_n = normalize(ref_text, keep_punct)
    hyp_n = normalize(hyp_text, keep_punct)
    if not ref_n or not hyp_n:
        return None
    try:
        return jiwer.wer(ref_n, hyp_n)
    except ValueError:
        return None


def punct_count(text):
    return sum(1 for c in text if c in ".,?!;:")


def upper_word_ratio(text):
    words = text.split()
    if not words:
        return 0.0
    caps = sum(1 for w in words if w[:1].isupper())
    return caps / len(words)


def load_json(path):
    if not path.exists():
        return None
    return json.loads(path.read_text())


def word_diff_snippets(ref_text, hyp_text, label, max_snippets=10):
    ref_words = normalize(ref_text).split()
    hyp_words = normalize(hyp_text).split()
    sm = SequenceMatcher(None, ref_words, hyp_words, autojunk=False)
    snippets = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        ctx = 4
        r_start = max(0, i1 - ctx)
        r_end = min(len(ref_words), i2 + ctx)
        h_start = max(0, j1 - ctx)
        h_end = min(len(hyp_words), j2 + ctx)
        snippets.append(
            {
                "tag": tag,
                "reference": " ".join(ref_words[r_start:r_end]),
                "hypothesis": " ".join(hyp_words[h_start:h_end]),
                "ref_span": " ".join(ref_words[i1:i2]),
                "hyp_span": " ".join(hyp_words[j1:j2]),
            }
        )
    # Prefer larger disagreements (more informative) for the top N.
    snippets.sort(key=lambda s: len(s["ref_span"]) + len(s["hyp_span"]), reverse=True)
    return snippets[:max_snippets]


def main():
    per_meeting = {}
    for key in MEETINGS:
        whisper = load_json(WHISPER_OUT / f"{key}.json")
        sa_t = load_json(SA_OUT / f"{key}.transcriber.json")
        sa_d = load_json(SA_OUT / f"{key}.dictation.json")
        pk = load_json(PARAKEET_OUT / f"{key}.json")

        if whisper is None:
            print(f"WARNING: no whisper reference for {key}, skipping", file=sys.stderr)
            continue

        ref_text = whisper["text"]
        entry = {
            "label": LABELS.get(key, key),
            "reference_chars": len(ref_text),
            "reference_wall_ms": whisper.get("wall_ms"),
            "models": {},
        }

        candidates = {
            "sa_transcriber": sa_t,
            "sa_dictation": sa_d,
            "parakeet": pk,
        }
        for name, data in candidates.items():
            if data is None or data.get("error"):
                entry["models"][name] = {"error": data.get("error") if data else "missing"}
                continue
            hyp_text = data["text"]
            core = wer(ref_text, hyp_text, keep_punct=False)
            punct = wer(ref_text, hyp_text, keep_punct=True)
            model_entry = {
                "wer_core": core,
                "wer_punct_sensitive": punct,
                "punct_count": punct_count(hyp_text),
                "upper_word_ratio": round(upper_word_ratio(hyp_text), 4),
                "char_count": len(hyp_text),
                "segment_count": data.get("segment_count", len(data.get("segments", []))),
            }
            if "wall_ms" in data:
                model_entry["wall_ms"] = data["wall_ms"]
            if "word_timestamp_count" in data:
                model_entry["word_timestamp_count"] = data["word_timestamp_count"]
                total_words = len(hyp_text.split())
                model_entry["word_timestamp_coverage"] = (
                    round(data["word_timestamp_count"] / total_words, 4) if total_words else None
                )
            entry["models"][name] = model_entry

        # Direct SpeechAnalyzer <-> Parakeet agreement (no reference needed).
        if sa_t and not sa_t.get("error") and pk:
            entry["sa_transcriber_vs_parakeet_wer"] = wer(pk["text"], sa_t["text"])
        if sa_d and not sa_d.get("error") and pk:
            entry["sa_dictation_vs_parakeet_wer"] = wer(pk["text"], sa_d["text"])

        per_meeting[key] = entry

    # Aggregate (mean across meetings with a valid score for each model).
    aggregate = {"models": {}}
    for model in ("sa_transcriber", "sa_dictation", "parakeet"):
        cores = [
            e["models"][model]["wer_core"]
            for e in per_meeting.values()
            if model in e["models"] and e["models"][model].get("wer_core") is not None
        ]
        puncts = [
            e["models"][model]["wer_punct_sensitive"]
            for e in per_meeting.values()
            if model in e["models"] and e["models"][model].get("wer_punct_sensitive") is not None
        ]
        aggregate["models"][model] = {
            "mean_wer_core": round(sum(cores) / len(cores), 4) if cores else None,
            "mean_wer_punct_sensitive": round(sum(puncts) / len(puncts), 4) if puncts else None,
            "n_meetings": len(cores),
        }

    comparison = {"per_meeting": per_meeting, "aggregate": aggregate}
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "comparison.json").write_text(json.dumps(comparison, indent=2))

    # Worst-agreement meeting = highest mean of the two SA<->Parakeet WERs.
    def agreement_score(e):
        vals = [
            v
            for v in (e.get("sa_transcriber_vs_parakeet_wer"), e.get("sa_dictation_vs_parakeet_wer"))
            if v is not None
        ]
        return sum(vals) / len(vals) if vals else -1

    worst_key = max(per_meeting, key=lambda k: agreement_score(per_meeting[k])) if per_meeting else None

    # Markdown report.
    lines = []
    lines.append("# S2 STT Eval — SpeechAnalyzer vs Parakeet vs Whisper-large-v3\n")
    lines.append(
        "Whisper-large-v3 (mlx-whisper, `mlx-community/whisper-large-v3-mlx`) is used as a "
        "**comparative pseudo-gold reference only** — not absolute truth. All three systems "
        "(SpeechAnalyzer x2 modes, Parakeet) are scored against it; ties are broken by manual "
        "review of the disagreement snippets below.\n"
    )
    lines.append("## Per-meeting WER (core / punctuation-sensitive)\n")
    lines.append("| Meeting | SA-transcriber | SA-dictation | Parakeet |")
    lines.append("|---|---|---|---|")
    for key in MEETINGS:
        if key not in per_meeting:
            continue
        e = per_meeting[key]
        row = [e["label"]]
        for model in ("sa_transcriber", "sa_dictation", "parakeet"):
            m = e["models"].get(model, {})
            if m.get("error"):
                row.append(f"ERROR: {m['error']}")
            else:
                core = m.get("wer_core")
                punct = m.get("wer_punct_sensitive")
                row.append(
                    f"{core:.3f} / {punct:.3f}" if core is not None and punct is not None else "n/a"
                )
        lines.append("| " + " | ".join(row) + " |")

    lines.append("\n## Aggregate mean WER (core / punctuation-sensitive)\n")
    lines.append("| Model | Mean core WER | Mean punct-sensitive WER | N meetings |")
    lines.append("|---|---|---|---|")
    for model in ("sa_transcriber", "sa_dictation", "parakeet"):
        a = aggregate["models"][model]
        lines.append(
            f"| {model} | {a['mean_wer_core']} | {a['mean_wer_punct_sensitive']} | {a['n_meetings']} |"
        )

    lines.append("\n## Direct SpeechAnalyzer <-> Parakeet agreement (WER, core-normalized)\n")
    lines.append("| Meeting | SA-transcriber vs Parakeet | SA-dictation vs Parakeet |")
    lines.append("|---|---|---|")
    for key in MEETINGS:
        if key not in per_meeting:
            continue
        e = per_meeting[key]
        t = e.get("sa_transcriber_vs_parakeet_wer")
        d = e.get("sa_dictation_vs_parakeet_wer")
        lines.append(
            f"| {e['label']} | {f'{t:.3f}' if t is not None else 'n/a'} | {f'{d:.3f}' if d is not None else 'n/a'} |"
        )

    lines.append("\n## Punctuation / casing presence\n")
    lines.append("| Meeting | Model | Punct marks | Uppercase-word ratio |")
    lines.append("|---|---|---|---|")
    for key in MEETINGS:
        if key not in per_meeting:
            continue
        e = per_meeting[key]
        for model in ("sa_transcriber", "sa_dictation", "parakeet"):
            m = e["models"].get(model, {})
            if m.get("error"):
                continue
            lines.append(
                f"| {e['label']} | {model} | {m.get('punct_count')} | {m.get('upper_word_ratio')} |"
            )

    lines.append("\n## Word-timestamp coverage (SpeechAnalyzer only)\n")
    lines.append(
        "Parakeet's DB rows carry SEGMENT-level `audio_start_time`/`audio_end_time` only — "
        "no word-level timestamps exist in the shipped output, so no coverage number applies "
        "there (this is itself a capability gap SpeechAnalyzer would close if adopted).\n"
    )
    lines.append("| Meeting | SA-transcriber word-ts coverage | SA-dictation word-ts coverage |")
    lines.append("|---|---|---|")
    for key in MEETINGS:
        if key not in per_meeting:
            continue
        e = per_meeting[key]
        t = e["models"].get("sa_transcriber", {}).get("word_timestamp_coverage")
        d = e["models"].get("sa_dictation", {}).get("word_timestamp_coverage")
        lines.append(f"| {e['label']} | {t} | {d} |")

    lines.append("\n## Runtime (wall-clock ms)\n")
    lines.append("| Meeting | SA-transcriber | SA-dictation | Whisper-large-v3 (reference) |")
    lines.append("|---|---|---|---|")
    for key in MEETINGS:
        if key not in per_meeting:
            continue
        e = per_meeting[key]
        t = e["models"].get("sa_transcriber", {}).get("wall_ms")
        d = e["models"].get("sa_dictation", {}).get("wall_ms")
        r = e.get("reference_wall_ms")
        lines.append(
            f"| {e['label']} | {f'{t/1000:.1f}s' if t else 'n/a'} | {f'{d/1000:.1f}s' if d else 'n/a'} "
            f"| {f'{r/1000:.1f}s' if r else 'n/a'} |"
        )
    lines.append(
        "\nParakeet runtime is not measured here — its transcript was already produced during "
        "normal app recording, not re-run for this eval.\n"
    )

    if worst_key:
        lines.append(
            f"\n## Worst SpeechAnalyzer<->Parakeet agreement: **{per_meeting[worst_key]['label']}**\n"
        )
        lines.append(f"See `disagreements/{worst_key}.md` for aligned snippets.\n")

    (RESULTS / "COMPARISON.md").write_text("\n".join(lines))
    print(f"Wrote {RESULTS / 'comparison.json'} and {RESULTS / 'COMPARISON.md'}")

    # Disagreement dump for the worst-agreement meeting.
    if worst_key:
        DISAGREEMENTS.mkdir(parents=True, exist_ok=True)
        whisper = load_json(WHISPER_OUT / f"{worst_key}.json")
        sa_t = load_json(SA_OUT / f"{worst_key}.transcriber.json")
        sa_d = load_json(SA_OUT / f"{worst_key}.dictation.json")
        pk = load_json(PARAKEET_OUT / f"{worst_key}.json")
        ref_text = whisper["text"]

        md = [f"# Disagreement snippets — {LABELS.get(worst_key, worst_key)}\n"]
        md.append(
            "Reference = Whisper-large-v3 (pseudo-gold, not absolute truth). "
            "Each block shows the reference window and what each hypothesis said "
            "over the same aligned span. Spot-check which is actually right.\n"
        )
        for name, data in (("sa_transcriber", sa_t), ("sa_dictation", sa_d), ("parakeet", pk)):
            if data is None or data.get("error"):
                continue
            md.append(f"\n## vs {name}\n")
            snippets = word_diff_snippets(ref_text, data["text"], name, max_snippets=10)
            for i, s in enumerate(snippets, 1):
                md.append(f"\n**{i}. [{s['tag']}]**")
                md.append(f"- reference: `...{s['reference']}...`")
                md.append(f"- {name}: `...{s['hypothesis']}...`")
        (DISAGREEMENTS / f"{worst_key}.md").write_text("\n".join(md))
        print(f"Wrote {DISAGREEMENTS / (worst_key + '.md')}")


if __name__ == "__main__":
    main()
