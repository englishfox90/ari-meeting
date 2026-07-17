#!/usr/bin/env python3
"""Sanity-check @ref(MM:SS) / @ref(H:MM:SS) citations against each meeting's
real transcript time range (from the dumped prompt metadata). Read-only,
throwaway spike script."""
import json
import re
import sys

REF_RE = re.compile(r"@ref\((?:(\d+):)?(\d{1,2}):(\d{2})\)")


def to_seconds(h, m, s):
    h = int(h) if h else 0
    return h * 3600 + int(m) * 60 + int(s)


def check(result_path, prompt_path):
    result = json.load(open(result_path))
    prompt = json.load(open(prompt_path))
    text = result.get("text", "")
    time_range = prompt["timeRange"]
    refs = REF_RE.findall(text)
    n_in_range = 0
    n_out_of_range = 0
    bad = []
    for h, m, s in refs:
        secs = to_seconds(h, m, s)
        if time_range["minSeconds"] - 1 <= secs <= time_range["maxSeconds"] + 1:
            n_in_range += 1
        else:
            n_out_of_range += 1
            bad.append(f"{h+':' if h else ''}{m}:{s} -> {secs}s")
    print(f"{result_path}:")
    print(f"  model={result.get('modelId')} meeting={result.get('meetingId')}")
    print(f"  timeRange={time_range}")
    print(f"  refs found={len(refs)} in_range={n_in_range} out_of_range={n_out_of_range}")
    if bad:
        print(f"  BAD REFS: {bad}")
    print()


if __name__ == "__main__":
    pairs = [
        ("results/qwen-adhoc.json", "prompts/adhoc-with-nia.json"),
        ("results/qwen-servicing.json", "prompts/servicing-org-strategy.json"),
        ("results/gemma-adhoc.json", "prompts/adhoc-with-nia.json"),
        ("results/gemma-servicing.json", "prompts/servicing-org-strategy.json"),
    ]
    for r, p in pairs:
        try:
            check(r, p)
        except Exception as e:
            print(f"{r}: ERROR {e}\n")
