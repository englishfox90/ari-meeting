# Product Context

Authoritative source: `meeting-intelligence-prd.md` (repo root). This is a distilled summary — the PRD wins on any conflict.

## The bet: context

Off-the-shelf transcription tools treat every meeting as an isolated, anonymous event — the same colleague is "Speaker 2" in every meeting, and summaries are one-size-fits-all. Ari treats meetings as a **connected record of recurring people and recurring formats**, and feeds that context into every summary. That is the entire differentiator.

## Scope

- **Private, single-user, macOS-only** *for the current product*. By choice, for a small surface.
- We deliberately cross privacy boundaries the base avoided (calendar scope, persistent per-person state) because this is private and not distributed.
- **Non-goals (current product):** cross-platform (beyond Apple), cloud sync / accounts / multi-user (beyond the owner's own iCloud), external person enrichment (LinkedIn/data brokers), public distribution + notarization, silent auto-recording (recording is always prompted and consented).
- **Future direction (post Swift migration):** the Swift-native rewrite targets an **Apple multi-device family** for the *single owner* — a mobile ("lite") iOS/iPadOS app is a **separate, later project built after the macOS Swift migration completes** (see `plans/swift-migration-plan.md`, Phase 6). "Lite" = the same feature set as the Mac app **minus speaker identification (F1)**, since no proven on-device mobile diarization model exists yet. Text results sync across the owner's devices via **iCloud/CloudKit** (still single-user, no accounts/multi-user); audio stays device-local. This narrows the "macOS-only" and "cross-platform / cloud sync" non-goals above to *"one owner, Apple devices, private iCloud"* — it is not a move to general cross-platform or multi-user.

## Features (F1–F8)

| ID | Feature | Attaches at seam | Status |
|----|---------|------------------|--------|
| F1 | Persistent speaker identification (self-learning re-ID, confirm-before-enroll) | audio pipeline PCM tap | hard half (cross-meeting re-ID) already works; integration is the task |
| F2 | Person profiles — two-tier (authored identity + inferred facts w/ provenance & supersession) | DB / repository layer | net-new |
| F3 | Owner context injection into summary prompt | summary prompt assembly | net-new, low risk |
| F4 | Calendar integration via macOS EventKit (aggregates Google/Exchange, no OAuth) | net-new EventKit (Rust plugin or Swift sidecar) | net-new, needs entitlement |
| F5 | Calendar-triggered record prompt (never silent) | notifications/ + tray.rs | net-new, depends on F4 |
| F6 | Theme-based summary templates (1:1 / training / conference…) + auto-suggest | existing template registry | mostly authoring templates |
| F7 | Queryable meeting store (persistent embedding index over transcript chunks) | additive index alongside SQLite | extends existing recall |
| F8 | MCP / Claude extensibility (expose meeting store as MCP server) | multi-provider layer | net-new, interface design |

**Unifying stage — Context Assembly:** F2/F3/F4/F6 converge on one pipeline stage before summary generation. A `SummaryContext` is assembled from owner profile + attendee profiles (identified speakers) + call type (selects template) + transcript, then handed to the existing template-driven summary service. Both the template system and the injection point already exist; the net-new work is the *context providers* + a small assembler.

## Phasing (front-load low-risk value)

- **Phase 0 — Foundation:** resolve discovery questions (`open-questions.md`), confirm live audio path + PCM seam.
- **Phase 1 — Cheap/high-value:** F3 (owner context), F6 (templates), F7 (queryable store), F8 (MCP). All extend existing systems.
- **Phase 2 — Calendar:** F4 + F5. Unlocks attendee prior + call-type signal.
- **Phase 3 — Identity:** F1 re-ID + F2 profiles.
- **Phase 4 — Unification:** the `SummaryContext` stage + auto template selection.

The hardest, most uncertain work (F1, F2) lands last, after calendar + call-type signals that constrain and strengthen it exist.

## Consent & licensing

- **Recording is always prompted and consented** — never silent auto-record. Prompt-to-record respects two-party-consent jurisdictions even though Utah is one-party.
- App code: MIT (Zackriya copyright retained). Model weights carry their own licenses — Whisper/whisper.cpp MIT; **Parakeet (`parakeet-tdt-0.6b-v3`) is CC-BY-4.0 — attribution only** (settled 2026-07-16; the older "separate NeMo terms must be verified" concern is stale). Low-risk for private local use. Note for the Swift migration: FluidAudio's pyannote-derived diarization weights are also CC-BY-4.0.
