# prompt-harness

Standalone Node tool (unlike `tools/diarization_calibrate.py`, which is
Python) that reconstructs the app's "Call ③" final-report summary prompt
and drives it against real backends, so an S1 spike (MLX vs the current
Qwen 3.5 4B GGUF) has a real measuring stick instead of vibes.

This tool does **not** modify any product code
(`frontend/src-tauri/src/**`, `frontend/src/**`) — it only reads it, to stay
byte-for-byte faithful to what the real app sends the LLM.

**S1 status:** the MLX backends (`lib/backends/mlx.mjs` — Qwen3.5-4B-MLX,
`lib/backends/gemma.mjs` — Gemma 4 E4B) and the objective comparison tool
(`compare.mjs`) are now built — see "MLX backends" and "Objective comparison"
below.

## What "Call ③" is

The app assembles one specific prompt pair for the final markdown report:

- **system prompt** = `build_final_report_system_prompt()`
  (`frontend/src-tauri/src/summary/processor.rs:151`), built from a
  template's `to_section_instructions()` / `to_markdown_structure()`
  (`frontend/src-tauri/src/summary/templates/types.rs`).
- **user prompt** = `<transcript_chunks>…</transcript_chunks>` plus an
  optional `<user_context>` block (`processor.rs:483-491`). In the real
  pipeline that `<user_context>` block carries the F3 person/calendar
  context prefix (if any) followed by `TIMESTAMP_CITATION_INSTRUCTION` —
  both assembled on the **frontend**
  (`frontend/src/lib/summary/summaryOrchestrator.ts:143-146`,
  `frontend/src/lib/summary/summaryCore.ts:38-39`), not in Rust. Rust only
  wraps whatever string it's given.

`lib/prompt.mjs` ports every one of these literal strings verbatim, with a
`file:line` comment at each one, and reconstructs the same assembly (minus
F3 person/calendar context, since this harness has no access to that store
— it defaults to just the timestamp-citation instruction, matching the
frontend's own fallback when there's no person context to prepend).

**Known drift from the original task brief:** the brief described
`TIMESTAMP_CITATION_INSTRUCTION` as a Rust constant. It isn't — it's
TypeScript. `lib/prompt.mjs` follows the current source, not the brief; see
the comment block at the top of that file for the full explanation.

## Layout

```
tools/prompt-harness/
  lib/db.mjs                 read-only SQLite access (fixture listing + transcript loading)
  lib/prompt.mjs              Call ③ system/user prompt reconstruction
  lib/backends/llama.mjs      drives llama-helper (Qwen 3.5 4B GGUF) — the S1 BASELINE
  lib/backends/apple.mjs      drives apple-helper (FoundationModels on-device LLM)
  lib/backends/ollama.mjs     drives a local Ollama daemon (optional)
  lib/backends/mlx.mjs        MLX Qwen3.5-4B-MLX-4bit (S1 candidate 1)
  lib/backends/gemma.mjs      MLX Gemma 4 E4B 4bit (S1 candidate 2)
  lib/backends/mlxShared.mjs  shared subprocess driver both MLX backends use
  lib/backends/mlx_runner.py  the actual mlx_lm inference call (uv-run Python subprocess)
  lib/judge.mjs               OPTIONAL/ADVISORY `claude -p` blind pairwise judge
  extract.mjs                 CLI: picks the fixture set, writes fixtures/manifest.json
  run.mjs                     CLI: runs one backend over the fixture set
  abtest.mjs                  CLI: blind A/B rating between two run dirs — the REAL S1 gate
  compare.mjs                 CLI: objective citation/attribution/section/cost scoring
  fixtures/manifest.json      COMMITTED — meeting ids/titles/dates only, no transcript text
  fixtures/cache/             gitignored — not currently used by run.mjs (which re-queries
                               the DB live each run), reserved if a future backend wants a
                               cached transcript dump
  runs/                       gitignored — backend outputs, COMPARISON.md, comparison.json
```

## Privacy posture

- The DB is opened **read-only**: `mode=ro&immutable=1` in the connection
  URI **and** `PRAGMA query_only = ON` as an independent second guard
  (`lib/db.mjs`, mirroring `tools/diarization_calibrate.py`). Verified by
  hand: an `INSERT` against a DB opened this way throws `attempt to write a
  readonly database`.
- `fixtures/manifest.json` is the only fixture-related file meant to be
  **committed** — it holds meeting ids, titles, dates, and line counts as
  "pointers to calibrated recordings." It never holds transcript text or
  summary output.
- `runs/*` (backend outputs, which DO contain real transcript-derived
  summary text) and `fixtures/cache/*` are gitignored. Don't remove those
  `.gitignore` entries.

## Usage

### 1. Extract the fixture set

```bash
node extract.mjs                      # up to 10 meetings, newest first
node extract.mjs --count 5            # fewer, if you want a quick smoke set
node extract.mjs --db /path/to/other.sqlite
```

Prints (and writes to `fixtures/manifest.json`) exactly how many real
meetings with transcripts exist in the DB. **As of 2026-07-16 this machine's
DB has 9 meetings with transcripts** — one short of S1's "≥10 real
transcripts" bar; re-run `extract.mjs` once more meetings accumulate.

### 2. Run a backend over the fixture set

```bash
# The baseline the S1 candidate must match or beat:
node run.mjs --backend llama --label baseline

# Apple on-device (only useful for short meetings — see caveat below):
node run.mjs --backend apple --label apple-check --limit 2

# Ollama (any locally pulled model):
node run.mjs --backend ollama --label gemma3-4b --model gemma3:4b
```

Flags: `--label` (required, names the output dir `runs/<backend>-<label>/`),
`--limit N` (only the first N fixture meetings), `--template ID` (force a
template id instead of each meeting's saved `template_id` / the
`standard_meeting` default), `--model NAME` (ollama only), `--db PATH`.

Each meeting writes `runs/<backend>-<label>/<meetingId>.json`:
`{meetingId, title, templateId, backend, model, lineCount, ok, text|error, elapsedMs}`.
A `_summary.json` records the aggregate pass/fail count.

**Apple FoundationModels caveat (verified, not a bug):** the on-device
model has a small (~4k token) context window — the app itself gates
`AppleFoundation` chunking at a 3500-token threshold
(`frontend/src-tauri/src/summary/service.rs`). Every one of the 9 real
fixture meetings (110-403 transcript lines) is too long for a single-pass
`summarize` call and will fail with "Exceeded model context window size."
This is honest, expected behavior, not a harness defect — confirmed by
running a truncated 20-line slice of a real transcript through the same
code path successfully.

### 3. Blind A/B rate two runs (the S1 pass bar)

```bash
node abtest.mjs --baseline runs/llama-baseline --candidate runs/mlx-candidate-v1
```

For every meeting present in both run dirs, shows both summaries as
anonymous "Summary A" / "Summary B" (randomized per meeting) and asks
`a`/`b`/`tie`/`s` (skip)/`q` (quit-and-save). Reveals which was which only
after you answer, then tallies a verdict from the CANDIDATE's perspective:
`better` / `same` / `worse`. Progress is saved to a `*.ratings.json` file
after every answer (safe to Ctrl-C and resume — already-rated meetings are
skipped on the next run). Prints the final tally:

```
Verdict tally (candidate vs baseline): better=X same=Y worse=Z
S1 bar: candidate >= baseline on (X+Y)/N rated meetings
```

## MLX backends

Two MLX candidates are wired in, both via `lib/backends/mlxShared.mjs` ->
`lib/backends/mlx_runner.py`, a subprocess driven with
`uv run --with mlx-lm python3 …` (same ad-hoc-Python-dep convention as
`tools/diarization_calibrate.py` — no committed venv, no product-code
dependency).

- **`mlx.mjs`** — `mlx-community/Qwen3.5-4B-MLX-4bit` (4-bit, ~2.9 GB on
  disk). Chosen as the closest same-size, same-quant-tier, **un-gated**
  MLX build of the exact model the app ships
  (`Qwen3.5-4B-Q4_K_M.gguf`) — verified against the repo's `config.json`
  (`model_type: "qwen3_5"`, 4-bit `quantization_config`).
- **`gemma.mjs`** — `mlx-community/gemma-4-e4b-it-4bit` (4-bit, ~4.8 GB on
  disk, un-gated). Gemma 4 E4B: elastic/MatFormer family, ~4.5B effective
  active params, 128K context, so the **full transcript fits in one pass**
  (no chunking, unlike `apple.mjs`'s ~4k-token FoundationModels ceiling).

Both HF repos are published with a multimodal ("ForConditionalGeneration")
config (image/audio token ids, `pipeline_tag: image-text-to-text`) — but
`mlx_lm`'s own model classes for both architectures
(`qwen3_5.py::Model.sanitize`, `gemma4.py::Model.sanitize`, read directly
from the installed package, not assumed) strip
`vision_tower`/`audio_tower`/`multi_modal_projector`/`embed_vision`/
`embed_audio` weights and load only the text tower. So `mlx_lm.load()`
loads a pure text-generation model despite the repo's pipeline tag; the
extra vision/audio bytes download but are never used.

**Fair-comparison contract:** every backend gets the identical `{system,
user}` Call ③ content. `mlx_runner.py` applies **each model's own** chat
template via `tokenizer.apply_chat_template(messages, tokenize=False,
add_generation_prompt=True, enable_thinking=False)` — never the Qwen
GGUF's hand-rolled `<|im_start|>` wrapping. `enable_thinking=False` mirrors
the app's own `QWEN35_NONTHINKING_TEMPLATE` (which starts the assistant
turn with an empty `<think></think>` block) so the comparison measures the
final report, not reasoning-trace verbosity; Gemma's template doesn't
define that kwarg, so it's a silent no-op there (Jinja renders with unused
context vars fine — verified by running both models with the flag).
Sampling: `temperature=0.5, top_p=0.8` on both MLX backends, chosen to
mirror the two knobs `llama.mjs`'s `QWEN35_SUMMARY_SAMPLING` sets for the
GGUF baseline. `mlx_lm`'s sampler has no direct equivalent of
llama.cpp's `presence_penalty`/`repeat_penalty` — that's a real,
acknowledged asymmetry, not an oversight.

Models download on first use via `mlx_lm`'s HF cache
(`~/.cache/huggingface`), several GB each — never committed.

```bash
node run.mjs --backend mlx --label qwen-mlx        # MLX Qwen3.5-4B (S1 candidate 1)
node run.mjs --backend gemma --label gemma-e4b     # MLX Gemma 4 E4B (S1 candidate 2)
```

## Objective comparison (compare.mjs)

```bash
node compare.mjs --runs runs/llama-baseline runs/mlx-qwen-mlx runs/gemma-gemma-e4b
node compare.mjs --runs runs/llama-baseline runs/mlx-qwen-mlx --judge claude   # + advisory judge
```

For every run dir given, scores each meeting's summary against that
meeting's REAL transcript (read via `lib/db.mjs`, same read-only DB as
everything else here):

- **Citation validity** — parses every `@ref(MM:SS)`/`@ref(H:MM:SS)` marker
  and checks it against the exact set of real transcript-line timestamps
  (not just "in range"): `valid` (matches a real line), `unmatched`
  (inside the meeting's duration but no real line at that second — still a
  fabricated citation), `outOfRange` (past the meeting's end or negative).
- **Speaker attribution sanity** — extracts `Name:` -style attributions
  from the summary and checks each against the meeting's real speaker/
  person names (first-name-only matches count as known).
- **Section completeness** — checks every template section title appears
  as a `**Title**` header, plus whether the main `# Title` heading exists.
- **Format/refusal failures** — generation errors, empty/too-short output,
  refusal phrases, missing main title, or template ignored entirely.
- **Cost** — wall-clock `elapsedMs` for every backend, plus MLX-only
  `latencyMs`/`loadMs`/`peakRssMb` from `mlx_runner.py`.

Writes `runs/comparison.json` (raw data) and `runs/COMPARISON.md`
(aggregate + per-meeting markdown tables). This is decision-grade data —
but **not** a replacement for the human blind A/B below.

The optional `--judge claude` pass (see `lib/judge.mjs`) runs a blind,
randomized pairwise comparison per meeting through `claude -p` and tallies
wins — **advisory only**, skipped silently if the `claude` CLI isn't on
PATH. It is explicitly not the S1 gate.

## Full S1 loop

```bash
cd tools/prompt-harness
node extract.mjs                                              # refresh the fixture manifest
node run.mjs --backend llama --label baseline                 # the current app's behavior
node run.mjs --backend mlx --label qwen-mlx                    # S1 candidate 1
node run.mjs --backend gemma --label gemma-e4b                 # S1 candidate 2
node compare.mjs --runs runs/llama-baseline runs/mlx-qwen-mlx runs/gemma-gemma-e4b
node abtest.mjs --baseline runs/llama-baseline --candidate runs/mlx-qwen-mlx      # the real gate
node abtest.mjs --baseline runs/llama-baseline --candidate runs/gemma-gemma-e4b   # the real gate
```

## Correctness notes / verified facts (2026-07-16)

- **llama-helper protocol** (`llama-helper/src/main.rs`): NDJSON on
  stdin/stdout. Request `{"type":"generate","prompt":...,"model_path":...,
  "context_size":...,"max_tokens":...,<sampling>}` → response
  `{"type":"response","text":...,"error":null|string}`. Verified against
  source, not just the task memo.
- **Qwen chat template** (`frontend/src-tauri/src/summary/summary_engine/models.rs`):
  `QWEN35_NONTHINKING_TEMPLATE` starts the assistant turn with an empty
  `<think></think>` block; `escape_user_prompt_control_markers` escapes
  control tokens **in the user prompt only**, never the system prompt.
  Sampling is `SamplingParams::qwen35_summary`: temperature 0.5, top_k 20,
  top_p 0.8, presence_penalty 0.3, repeat_penalty 1.05, penalty_last_n 256,
  stop `["<|im_end|>"]`. Model: `qwen3.5:4b` →
  `Qwen3.5-4B-Q4_K_M.gguf`, context_size 32768.
- **apple-helper protocol** (`apple-helper/Sources/apple-helper/Protocol.swift`,
  `main.swift`): NDJSON, camelCase, distinct `type` per message (not one
  generic "response" tag) — confirmed by direct probe + summarize calls on
  this machine (FoundationModels IS available here: `probeResult` returned
  all-true).
- **Ollama**: `options.num_ctx` is set explicitly (16384 by default) to
  avoid Ollama's default ~4k-token silent truncation — this exact failure
  mode is why the app's own `service.rs` fetches real model context via
  `METADATA_CACHE.get_or_fetch` instead of trusting a default.
- **DB opened read-only**, verified: an `INSERT` against the read-only
  connection throws `attempt to write a readonly database`.
- **End-to-end proof** (this machine, 2026-07-16): `node run.mjs --backend
  llama --label baseline-test --limit 2` produced two non-empty, on-topic
  summaries (6221 and ~6000+ chars) with real `@ref(MM:SS)` citations tied
  to real transcript timestamps and real attendee names (11 and 42 `@ref`
  citations respectively). `apple-helper` probe reported full availability
  on this machine; a truncated 20-line real-transcript slice produced a
  correct `summarizeResult`. Ollama (`gemma3:4b`, already running locally)
  produced a real summary in ~51s. The Ollama-unreachable path was verified
  separately by pointing the backend at a closed port — it throws a clear,
  catchable "Ollama unreachable... is the daemon running?" error rather
  than hanging or silently returning nothing.
