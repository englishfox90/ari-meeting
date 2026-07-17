# Plan: Apple on-device transcription (SpeechAnalyzer) + summaries (FoundationModels)

## Context

Ari currently transcribes with Parakeet/Whisper (bundled model weights, ~640 MB–2.6 GB
downloads) and summarizes with a bundled llama.cpp sidecar or cloud/CLI providers. Apple ships
**system-level** on-device models on macOS 26 (Tahoe) — `SpeechAnalyzer`/`SpeechTranscriber`
(Speech framework) for STT and `FoundationModels` for LLM — with **zero app footprint** (assets
live at the OS level via `AssetInventory`) and no cloud/API cost. This machine is Darwin 25.5
(macOS 26), so the APIs are available.

Both frameworks are **Swift-only**, and our existing Apple-bindings crate `cidre` has no
`Speech`/`FoundationModels` support (only speech *synthesis*). So this is net-new: a **Swift
sidecar** driven exactly like the existing `llama-helper` (bundled binary, newline-delimited JSON
over stdin/stdout), plus additive Rust providers and Settings UI.

**Decisions (confirmed):** (1) Apple STT works **live during recording** as well as for imports /
re-transcription. (2) The live notch/menu-bar transcription overlay is **out of scope** here —
documented as a follow-on that consumes the same live stream.

**Hard requirements:** macOS 26 + Apple Silicon + **Apple Intelligence enabled**. The UI must gate
honestly (No-Fake-State): only offer Apple providers when a runtime probe confirms availability,
and show real asset-download state.

**Verification caveat:** I can write all of this, but it cannot be fully run/verified from here —
it needs your Xcode 26 toolchain, Apple-Intelligence-enabled hardware, and the signed
`pnpm run app:local` flow. Verification steps are at the end.

---

## Architecture decision: one persistent Swift sidecar, per-segment request/response

`llama-helper` establishes the pattern we reuse verbatim: `externalBin` for bundling only; the
process is spawned and driven manually with `tokio::process::Command` over **newline-delimited
JSON, one object per line** (`summary/summary_engine/sidecar.rs` + `client.rs`).

New sidecar **`apple-helper`** (SwiftPM executable) speaks the same protocol:

| Request (one JSON line) | Response |
|---|---|
| `{"type":"probe"}` | `{"type":"response","speechAvailable":bool,"foundationAvailable":bool,"osOk":bool,"appleIntelligence":bool,"speechAssetsInstalled":bool}` |
| `{"type":"ensureAssets","which":"speech"}` | progress lines `{"type":"progress","fraction":..}` then `{"type":"response","installed":true}` |
| `{"type":"transcribe","pcmBase64":"<LE f32 16k mono>","locale":"en-US"}` | `{"type":"response","text":..,"confidence":..}` |
| `{"type":"summarize","text":..,"instruction":..,"maxTokens":..}` | `{"type":"response","text":..}` |
| any | `{"type":"error","message":..}` |

**Why per-segment (not a live streaming session):** the existing STT abstraction
(`audio/transcription/provider.rs` `TranscriptionProvider::transcribe(audio: Vec<f32>, language)`)
is segment-in → text-out, and Whisper/Parakeet already work that way for **both** live and file
paths (live worker calls `TranscriptionEngine`, file paths call the engines per VAD segment). If we
implement Apple STT as a `TranscriptionProvider` that ships each VAD segment to the sidecar and gets
text back, we get **live + file** with **no pipeline/worker surgery** — the live worker
(`audio/transcription/worker.rs`) already routes through `TranscriptionEngine::Provider(Arc<dyn
TranscriptionProvider>)`. The sidecar keeps a warm `SpeechAnalyzer`/`SpeechTranscriber` and
finalizes per request. PCM is base64 little-endian f32 (segments, not 600 ms windows, so call
frequency is modest).

- **Implementation checkpoint:** confirm the live worker passes complete VAD *segments* (not tiny
  fixed windows) to the engine. If it passes sub-second windows, quality degrades; fallback is a
  stateful sidecar session (`stt.start`/`stt.audio`/`stt.stop` with async result lines routed to a
  channel). Primary plan assumes per-segment; note the fallback in code comments.

FoundationModels has a **4k-token context window** → chunk + merge. `summary/processor.rs:369`
already chunks for local providers below a token threshold; add `AppleFoundation` to that set with a
~3.5k-token budget so long transcripts are split, summarized per-chunk, and merged (existing path).

---

## Components & files

### A. New Swift sidecar — `apple-helper/` (repo root, SwiftPM)
- `apple-helper/Package.swift` + `Sources/apple-helper/main.swift`: read stdin lines, dispatch the
  protocol above. `import Speech` (SpeechAnalyzer/SpeechTranscriber, `AssetInventory`) and
  `import FoundationModels` (`LanguageModelSession`/guided generation). `@available(macOS 26, *)`
  gating; `probe` returns availability instead of crashing on older OS.
- Build + stage (mirror `llama-helper`): `swift build -c release` → copy to
  `frontend/src-tauri/binaries/apple-helper-aarch64-apple-darwin`.
  - Extend `frontend/scripts/run-local.sh` (the `SIDECAR` staging block at lines ~21,33-40) to also
    build/copy `apple-helper`.
  - Add `"binaries/apple-helper"` to `externalBin` in `frontend/src-tauri/tauri.conf.json:103-106`.
  - Dev resolution: mirror `sidecar.rs::resolve_helper_binary()` fallback to `target/...` /
    next-to-exe / `RESOURCE_DIR` so `pnpm run tauri:dev` finds it too.
- **Entitlements/signing:** Speech + FoundationModels may require entitlements; the sidecar is a
  separate signed binary. Add needed entitlements to the sidecar and/or main app and confirm under
  the `Ari Dev Signing` identity used by `app:local`. (Flagged as a build task — exact entitlement
  keys verified during implementation.)

### B. Rust — sidecar manager + providers (all additive)
- `src/apple/mod.rs` + `src/apple/helper.rs`: singleton manager mirroring
  `summary/summary_engine/sidecar.rs` (spawn, `send_request`, health/idle, generous read timeout —
  transcription can take longer than a chat token). Public fns: `probe()`, `ensure_assets()`,
  `transcribe(pcm, locale)`, `summarize(text, instruction, max_tokens)`. Declare `pub mod apple;` in
  `lib.rs`.
- `src/audio/transcription/apple_provider.rs`: `struct AppleTranscriptionProvider` impl
  `TranscriptionProvider` → base64-encodes samples, calls `apple::helper::transcribe`, returns
  `TranscriptResult`. Register in `audio/transcription/engine.rs` `get_or_init_transcription_engine`
  (lines ~186-219) with a new explicit `"apple" =>` arm returning
  `TranscriptionEngine::Provider(Arc::new(...))` **before** the catch-all `_ => whisper`.
- File paths: add an Apple branch to the per-segment `if use_parakeet {…} else {…}` blocks in
  `audio/import.rs` (~582-596) and `audio/retranscription.rs` (~371-385), selected when the
  provider arg/config is `"apple"`. (Same seam Parakeet already occupies; additive branch.)
- Summary provider: in `summary/llm_client.rs` add `LLMProvider::AppleFoundation`, a `from_str`
  arm (`"apple-foundation"`), an **early-return** branch (like `BuiltInAI`/`ClaudeCLI`) calling
  `apple::helper::summarize`, `provider_name`, and the two exhaustive-match `unreachable!()` arms.
  Add it to the no-API-key set in `summary/service.rs` and to the chunking set in
  `summary/processor.rs:369` (~3.5k threshold).
- Tauri commands (register in `lib.rs` `generate_handler!`): `apple_probe`, `apple_ensure_assets`
  (emits progress events for the download UI). Follows the existing two-edit command rule.

### C. Frontend — Settings (additive, mirrors the `claude-cli` work just done)
- **Transcription** (`src/components/TranscriptSettings.tsx`): add `'apple'` to the provider union
  (line 13) and a `<SelectItem value="apple">Apple (on-device)</SelectItem>` (lines ~124). Gate it
  on `apple_probe`; when selected, show honest status + an "Install speech assets" action wired to
  `apple_ensure_assets` with real progress (No-Fake-State). No API key.
- **Summary** (`src/components/ModelSettingsModal.tsx`): add `'apple-foundation'` to the provider
  union (line 35), the model map (~243), and a `<SelectItem>` with a probe-driven status block —
  identical pattern to the `claude-cli` block added earlier (detection + honest "not available"
  state, no API key). Propagate the union to `src/services/configService.ts:12` and
  `src/contexts/ConfigContext.tsx` `modelOptions` (must list every provider or `tsc` fails).
- Icons: add an Apple glyph to `src/components/ProviderGlyphs.tsx` (`ProviderGlyph`/`ModelGlyph`),
  `currentColor`, never amber (Signal Rule).

### D. Persistence
- Transcription config already stores an arbitrary `provider` string in `transcript_settings`
  (`database/repositories/setting.rs`); `"apple"` needs **no migration** (parakeet takes no API key
  either — same code path). Summary config likewise stores the provider string. No schema change
  expected.

---

## Phasing (each independently shippable)

1. **Sidecar skeleton + probe** — `apple-helper` builds, bundles, and answers `probe`; `apple_probe`
   command + a status line in Settings. De-risks Swift build/sign/entitlements first.
2. **Summaries (FoundationModels)** — `summarize` mode + `AppleFoundation` provider + chunk/merge +
   ModelSettings UI. (Cleaner half; mirrors `claude-cli`.)
3. **Asset management** — `ensureAssets` + download-progress UI for Speech models.
4. **Transcription (SpeechAnalyzer)** — `transcribe` mode + `AppleTranscriptionProvider` +
   engine/import/retranscription wiring + TranscriptSettings UI. Live works automatically via the
   `Provider` path once registered; verify segment granularity (checkpoint above).

## Out of scope / follow-on
- **Notch / menu-bar live-transcription overlay** — natural next step; would add a live-stream event
  channel (Rust `emit` of incremental transcript) + an always-on-top overlay window. Deferred.
- Per-participant diarization (unchanged; F1 ceiling still applies to mixed system audio).

## Risks
- **Unverifiable here** — needs your hardware/Xcode/Apple-Intelligence toggle; ship behind the probe
  so a non-eligible machine simply doesn't see the options.
- **Entitlements** for Speech/FoundationModels on a bundled sidecar — the most likely build snag;
  phase 1 exists to surface it early.
- **FoundationModels quality/limits** — 4k context + Apple's guardrails may refuse or truncate;
  chunk/merge + honest error surfacing (reuse the summary failure path).
- **Live segment granularity** — if the worker feeds small fixed windows, fall back to a stateful
  streaming sidecar session (documented in code).
- **Additive-only** upheld: new sidecar, new modules, new commands, new provider variants; upstream
  edits confined to registration/branch seams (engine match arm, import/retx per-segment branch,
  llm_client enum + early-return, provider unions) — the same seams the `claude-cli` change used.

## Verification (run by you via the signed bundle)
1. Build the sidecar: `swift build -c release` in `apple-helper/` → copy to
   `binaries/apple-helper-aarch64-apple-darwin` (or via the extended `run-local.sh`).
2. `cd frontend && pnpm run app:local` (signed identity so TCC/Apple-Intelligence entitlements
   persist). Grant any prompts once.
3. **Probe:** Settings → transcription/summary sections show Apple options only if available; on an
   eligible machine both appear with a green "available" status.
4. **Summaries:** pick "Apple (on-device)" summary provider, generate a summary on an existing
   meeting; confirm output and that long transcripts chunk without error.
5. **Assets + transcription:** pick Apple transcription, install speech assets (real progress),
   then (a) import an audio file and (b) record a short live meeting — confirm transcripts populate
   from Apple STT in both.
6. Checks: `cargo check` + `cargo test` (root), `npx tsc --noEmit` + `node --test tests/lib/*.test.mjs`
   + `pnpm lint && pnpm build` (frontend). Update `DESIGN.json`/`DESIGN.md` in lockstep only if any
   token changes (none expected).
