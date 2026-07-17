# Kickoff prompt — Apple on-device STT + summaries (orchestrated)

> Paste everything below the line into a fresh Claude Code session at the repo root.
> It reproduces the architect-led, agent-orchestrated method used to deliver the Ari
> Notch feature. Read `plans/leverage-apple-models.md` first — that is the spec; this
> prompt is the *how we build it*.

---

You are the **architect** for delivering the Apple on-device transcription
(`SpeechAnalyzer`/`SpeechTranscriber`) + summaries (`FoundationModels`) feature specified in
`plans/leverage-apple-models.md`. You orchestrate the work across **Sonnet subagents**, but
**you personally review and approve every diff** and **independently re-run every quality gate**
— never merge on an agent's say-so. Optimize for code that survives your own scrutiny.

## The one governing rule: additive-only
New capability = new modules, new tables, new commands, new provider variants. Edit inherited
(upstream Meetily) files **only at registration points** (the `generate_handler!` list + `pub mod`
in `lib.rs`, provider enums, engine match arms, settings unions). Never refactor upstream code in
place. See `.claude/rules/additive-only.md`.

## Method — follow this exact sequence (it is what worked)

1. **Verify the seams BEFORE fanning out.** Dispatch read-only `Explore` agents to confirm every
   `file:line` the plan claims against the *current* code, reporting real lines and flagging drift.
   The plan's seams were audited once already — carry these known corrections forward and re-confirm:
   - `engine.rs` catch-all is `"localWhisper" | _` (not a bare `_`); insert the new `"apple" =>` arm
     before it.
   - **`validate_transcription_model_ready` (engine.rs ~90-145) also needs an `"apple"` arm** or live
     recording will reject the provider — the plan misses this.
   - Transcript api-key helpers `setting.rs` `save_transcript_api_key`/`get_transcript_api_key` each
     need an `"apple" => return Ok(())/Ok(None)` arm or they hit the `_ => Err("Invalid provider")`
     fallthrough (the parakeet precedent, lines ~184/216).
   - `TranscriptionProvider::transcribe(audio: Vec<f32>, language: Option<String>) -> TranscriptResult`
     is segment-in/text-out and the live worker already feeds **complete VAD segments** (confirmed) —
     so Apple STT as a `TranscriptionProvider` gets live+file with no worker surgery.
   - `llm_client.rs`: enum ~67-78, `from_str` ~82-94, early-return branches (`BuiltInAI`/`ClaudeCLI`)
     ~138-163, `provider_name` ~354-365, **two** exhaustive `unreachable!()` match arms ~211-218.
   - `service.rs` no-API-key set ~line 353; `processor.rs` chunking gate ~line 369 (negated set —
     add `&& provider != &AppleFoundation`).

2. **Resolve blockers FIRST**, before any agent writes feature code:
   - **Entitlements/signing** for Speech + FoundationModels on a bundled sidecar — the most likely
     build snag. Stand up a probe-only `apple-helper` skeleton that just answers `{"type":"probe"}`
     and confirm it builds + signs under the `Ari Dev Signing` identity via `pnpm run app:local`.
   - **Runtime availability probe** — the machine must be macOS 26 + Apple Silicon + Apple
     Intelligence enabled. `probe` must return availability instead of crashing on older OS
     (`@available(macOS 26, *)` gating). Everything gates honestly on this (No-Fake-State).

3. **Reuse the ari-notch sidecar infrastructure learnings** (do not rediscover them):
   - Model the manager on `summary/summary_engine/sidecar.rs` BUT write your **own** binary resolver
     for base name `apple-helper` — do NOT reuse `resolve_helper_binary` (it hard-codes `"llama-helper"`
     and wraps spawn in `nice`). See `frontend/src-tauri/src/notch/resolver.rs` for the pattern.
   - Stage the binary in `frontend/scripts/run-local.sh` (mirror the llama-helper/ari-notch blocks)
     and add `"binaries/apple-helper"` to `externalBin` in `tauri.conf.json`.
   - A **Swift 6.3 toolchain is present** in this environment — agents CAN and MUST `swift build`
     + `swift test`. Use the **shared-fixture cross-language conformance** pattern: JSON request/response
     fixtures that both the Rust side and a Swift test target decode, so the wire format has one source
     of truth.

4. **Make decision logic pure + unit-tested.** Factor chunk/merge budgeting, provider dispatch, and
   base64 PCM framing into side-effect-free functions tested without a live sidecar/Tauri/DB — the
   process glue stays thin. This is what makes the review real.

5. **Review gate after every agent.** Re-run yourself, don't trust the paste: `cargo check` +
   `cargo test` (root), `swift build -c release --arch arm64` + `swift test` (in `apple-helper/`),
   `npx tsc --noEmit` + `pnpm lint` + `node --test tests/lib/*.test.mjs` (frontend). Read the actual
   diff for additive-only compliance and the design-system rules (No-Fake-State honesty on
   availability/asset-download state; provider glyphs never amber).

6. **Interaction protocol.** Use `AskUserQuestion` only for genuine forks the code can't answer
   (e.g. per-segment vs stateful streaming session if the worker turns out to feed sub-second windows;
   whether to ship behind the probe only). Report at each **phase boundary** and get an OK before
   proceeding. Track work with tasks.

## Phasing (each independently shippable; front-load the risky Swift/entitlement work)
1. **Sidecar skeleton + probe** — `apple-helper` SwiftPM pkg builds, bundles, signs, answers `probe`;
   `apple_probe` Tauri command + an honest status line in Settings. De-risks build/sign/entitlements.
2. **Summaries (FoundationModels)** — `summarize` mode + `LLMProvider::AppleFoundation` (from_str,
   early-return, provider_name, both `unreachable!` arms, no-key set) + 4k-context chunk/merge via the
   `processor.rs:369` gate + ModelSettings UI (mirror the `claude-cli` block). Cleaner half; mostly Rust.
3. **Asset management** — `ensureAssets` + real download-progress events + UI (No-Fake-State).
4. **Transcription (SpeechAnalyzer)** — `transcribe` mode + `AppleTranscriptionProvider impl
   TranscriptionProvider` + the `"apple"` arms in `engine.rs` dispatch AND
   `validate_transcription_model_ready` + import/retranscription branches + TranscriptSettings UI.
   Live works automatically via the `Provider` path once registered; **verify VAD segment granularity**
   (the checkpoint in the plan) — fall back to a stateful `stt.start/audio/stop` sidecar session only
   if the worker feeds sub-second windows.

## Verification boundary — state it honestly, every time
- **Fully verifiable here:** all Rust (`cargo`), all Swift (`swift test` — toolchain present), all
  frontend (`tsc`/`lint`/tests). Verify these yourself.
- **Needs the user's hardware (cannot be run by agents):** anything requiring **Apple Intelligence
  enabled + macOS 26 runtime + the signed bundle** — actual STT output, real FoundationModels
  summaries, asset downloads, entitlement grants. Never claim these work from a static read; hand the
  user the exact `pnpm run app:local` steps and what to look for.

Begin by confirming scope with the user, then run step 1 (seam verification) and report before
fanning out.
