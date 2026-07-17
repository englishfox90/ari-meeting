# Ari Meeting App — Technical & Product Requirements

**Status:** Draft v0.1 · **Scope:** Private, single-user, macOS-only · **Base:** Fork of `henryvn27/meetily_improved` (MIT)

---

## 1. Purpose

A private, Mac-only Ari Meeting application that records and transcribes meetings, then produces summaries that are aware of *who is in the room*, *who owns the meeting*, and *what kind of meeting it is*. It extends an existing open-source base with persistent speaker identity, an accumulating per-person knowledge store, calendar-aware capture, theme-specific summary templates, and agent extensibility through MCP.

The distinguishing bet is context. Off-the-shelf transcription tools treat every meeting as an isolated, anonymous event. This app treats meetings as a connected record of recurring people and recurring formats, and feeds that context into every summary.

---

## 2. Background & Starting Point

The build starts from `meetily_improved`, a fork of Zackriya Solutions' Meetily. A file-level diff against upstream establishes what we inherit:

- The Rust/Tauri engine is upstream's. Of 144 Rust source files, 129 are byte-identical to upstream; 15 differ. The fork is upstream `0.4.0` plus roughly 2,000 lines of engine refinement (recording pipeline hardening, transcript storage, a VAD correctness fix shipped with a test) versioned as `0.5.0`, plus a rebuilt frontend and product docs.
- We therefore inherit, without building them: macOS system-audio and microphone capture, native Whisper and Parakeet speech-to-text engines (Metal-accelerated, no Python runtime), a multi-provider LLM layer (Anthropic, OpenRouter, Ollama, OpenAI, Groq), a SQLite persistence layer with a clean repository pattern, a summary template system, local notifications, a system-tray/menu-bar presence, and the UI.
- Two of our planned capabilities have no code in the tree and are fully net-new: speaker identification/diarization and calendar/EventKit integration.

Because this is a private application, we are free to cross the base's privacy boundaries (calendar scope, persistent per-person state) that its authors deliberately excluded. We are not contributing upstream, so their design-review norms do not bind us — but we still track upstream for maintenance (Section 8).

**License note.** The base is MIT with the original Zackriya copyright retained. Application code is unencumbered for private use. Model weights carry their own licenses independent of the app code — Whisper/whisper.cpp are MIT; Parakeet (NVIDIA NeMo) weights have separate terms that must be verified before any redistribution. For private, local use this is low-risk but worth recording.

---

## 3. Goals & Non-Goals

**Goals**

- Persistently identify recurring speakers across meetings and improve that identification over time.
- Maintain a local, accumulating profile of each person: an authored identity plus machine-inferred context (goals, interests, projects).
- Inject owner and attendee context into summaries so output is framed from the owner's vantage.
- Surface upcoming meetings from the calendar and prompt to record them.
- Produce summaries whose structure matches the meeting type (1:1, training, conference, etc.).
- Query the accumulated meeting record, and expose it to Claude/agents via MCP.

**Non-Goals**

- Cross-platform support. macOS only, by choice, for a smaller surface.
- Cloud sync, accounts, or multi-user collaboration.
- External person enrichment (LinkedIn, data brokers). All person context is user-authored or derived locally from transcripts.
- Public distribution and the signing/notarization/entitlement burden that implies. Personal-use signing only, unless scope changes.
- Silent auto-recording. Recording is always prompted and consented.

---

## 4. Problems We're Solving

**Speakers are anonymous and forgotten.** Standard tools segment a single meeting into "Speaker 1/2/3" and carry nothing between sessions. The same colleague is a stranger in every meeting. We want a person the tool recognizes by voice across months.

**There's no memory of who people are.** A transcript records what was said but not who said it, what they do, or what they care about. Summaries are poorer for it, and there's no way to ask "what has Alice been working toward this quarter" across meetings.

**Recording is manual and easy to forget.** The most common failure of any meeting tool is not being on when the meeting starts. The calendar already knows a meeting is coming; the tool should too.

**Summaries are one-size-fits-all.** A 1:1, a training session, and a conference talk need different summaries. A single generic template underserves all three.

**The record isn't queryable or extensible.** Meetings pile up as isolated documents. There's no good way to interrogate them across time, and no way for an external agent to reason over them.

**Summaries lack the owner's frame.** The tool doesn't know whose meeting this is, so it can't resolve the owner's jargon, attribute their action items, or write from their point of view.

---

## 5. Feature Breakdown

Each feature notes the problem it addresses, the high-level approach, where it attaches to the existing code, and the primary risk.

### F1 — Persistent Speaker Identification (self-learning re-ID)

*Problem:* speakers are anonymous across meetings.
*Approach:* a working local re-identification module (ported from an existing project) emits a stable `speaker_id` per transcript segment by matching a voice embedding against enrolled speakers and updating each speaker's centroid on confirmed matches — incremental, self-improving identification. New voices pass through a **confirm-before-enroll** gate to keep the store free of phantom speakers from one-off attendees and bad segments.
*Seam:* taps decoded PCM from the audio pipeline; runs as a separate module, independent of the STT engines.
*Risk:* diarizing *remote* participants is capped by macOS delivering system audio as a mixed stream — a hard ceiling, not a workload. Mitigated by leaning on the calendar attendee list to constrain the label space. In-room and per-process capture (if available) fare much better.
*Status:* the harder half — cross-meeting re-identification — already works; integration is the task.

### F2 — Person Profiles (two-tier, accumulating)

*Problem:* no memory of who people are.
*Approach:* two tiers kept separate. An **authored identity** (name, role, what they do, who they work for) editable only by the owner, and an **inferred tier** (goals, interests, projects they follow) proposed by extraction after each meeting. Extraction appends to the inferred tier only; it never overwrites authored identity. Every inferred fact carries provenance (meeting + segment + timestamp) and supersession (a later contradicting fact marks the earlier one stale rather than deleting it). Facts are tagged self-reported vs. attributed — what a person said about themselves outranks what someone else said about them. Low-confidence updates queue for a one-tap confirm.
*Seam:* new DB tables via the existing repository pattern; extraction runs post-meeting per speaker over that speaker's segments only.
*Risk:* silent quality decay from naive appending, and misattribution when speaker matching is wrong. Both are addressed by the provenance/supersession model and the confidence gate.

### F3 — Owner Context Injection

*Problem:* summaries lack the owner's frame.
*Approach:* a stored owner profile (identity, role, organization, domain) prepended to the summary prompt as a compact, labeled context block.
*Seam:* a settings field, injected at prompt assembly in the summary service.
*Risk:* minimal. Keep the block terse and factual to avoid biasing the model toward expected conclusions.

### F4 — Calendar Integration

*Problem:* recording is manual; attendees are unknown.
*Approach:* read the native macOS calendar via EventKit, which already aggregates Google/Exchange, so no third-party OAuth is required. Pull upcoming events, titles, times, and attendee lists; link an event to its resulting meeting record.
*Seam:* net-new EventKit access via a Tauri Rust plugin or a small Swift sidecar; requires the Calendars entitlement and a usage-description string.
*Risk:* entitlement and consent handling; attendee data quality varies by event.

### F5 — Calendar-Triggered Record Prompt

*Problem:* the most common failure is not being on when the meeting starts.
*Approach:* a local notification a few minutes before a calendar event, deep-linking to "start recording." Depends on F4.
*Seam:* extends the existing `notifications/` and `tray.rs` subsystems. A menu-bar-resident process (already supported) keeps the app alive to fire the prompt when closed.
*Risk:* macOS backgrounding reliability. Prompt-to-record only — never silent auto-record — to respect two-party-consent jurisdictions even though Utah is one-party.

### F6 — Theme-Based Summary Templates

*Problem:* one generic summary underserves distinct meeting types.
*Approach:* the engine already has a template system — a `Template` is a name, description, and a list of sections, each with its own LLM instruction and output format, loaded from JSON. Net-new work is largely authoring template files (`1on1`, `training`, `conference`, others) and adding template *selection*. Manual selection likely already exists; we add auto-suggestion of the right template, inferred from the calendar event (attendee count, title, recurrence) or, absent calendar data, from the distinct-speaker count. Selection is always a suggestion with a manual override.
*Seam:* new JSON templates in the existing registry; a small classifier feeding the existing selection path.
*Risk:* low. Mostly content design.

### F7 — Queryable Meeting Store

*Problem:* meetings pile up as isolated documents.
*Approach:* extend the base's existing recall feature with a persistent local embedding index (e.g., sqlite-vec, LanceDB, or Chroma) over transcript chunks so queries hold up across many meetings.
*Seam:* additive index alongside the existing SQLite store; wired into the existing query UI.
*Risk:* low; index maintenance and chunking strategy.

### F8 — MCP / Claude Extensibility

*Problem:* no agent can reason over the record.
*Approach:* expose the meeting store as an MCP server so Claude Desktop or a personal agent can query it as a tool, and/or use the existing provider layer's tool support to let the app call external MCP servers. This inverts cleanly with the home-agent work already underway.
*Seam:* builds on the existing multi-provider layer (Anthropic already wired) and the queryable store (F7).
*Risk:* low; interface design more than implementation.

### F9 — Meeting Series

*Problem:* recurring meetings pile up as isolated, disconnected instances — the fifth weekly 1:1 with a report knows nothing of the prior four, so open items, decisions, and running threads drown in a stack of one-offs. This is the failure mode the whole context bet exists to fix, applied to the *time* axis.
*Approach:* group meetings that are instances of the same recurring calendar event into a **series** (e.g. a weekly 1:1). Each series carries a living **ledger** — a compact running memory (open action items with carried status, decisions, recurring themes, per-person threads), capped at roughly 500 words. After each meeting's summary, a post-summary reduce updates the ledger; before the *next* meeting's summary, the ledger is injected into the prompt. A pile of isolated meetings becomes a threaded, progressing record. The series also carries a stable call type, priming template selection so later meetings inherit the series' template (F6).
*Detection:* rides on the existing calendar auto-match (F4). Recurring-event identity comes from the macOS EventKit `calendarItemExternalIdentifier`, which is stable across occurrences; enrollment is automatic with manual override (link/unlink/merge). A heuristic fallback groups non-calendar meetings by normalized title.
*Seam:* new DB tables (`meeting_series`, `meeting_series_members`, `series_ledger`) via the existing repository pattern; detection runs in calendar sync after auto-match; the ledger is read at the `SummaryContext` assembly / prompt-injection point (alongside owner and attendee context from F2/F3) and written by the post-summary reduce.
*Risk:* low, and additive. The F1 remote-diarization ceiling is unaffected. The ledger must honor No-Fake-State — it carries only real, observed items and never invents carried status — and stays terse to avoid summary-prompt bloat. Recording remains always-prompted and consented.
*Status:* built 2026-07-15 (additive: backend module, tables, and commands; frontend `/series` routes and breadcrumb; ledger engine). Runtime verification in the signed app is pending.

### Unifying stage — Context Assembly

F2, F3, F4, and F6 are not four independent features; they converge on a single pipeline stage that runs immediately before summary generation. A `SummaryContext` is assembled from the owner profile, the attendee profiles for the identified speakers, the call type (which selects the template), and the transcript, then handed to the existing template-driven summary service. Both the template system and the prompt-injection point already exist, so the net-new work is the *context providers* and a small assembler. The call-type signal earns double duty: it also shapes what facts F2 extracts per speaker (a 1:1 surfaces goals and blockers; a training surfaces who taught or learned what). F9's series ledger joins as one more context provider at this stage — read in before generation, written back after — extending the assembly across recurring instances of the same meeting.

---

## 6. High-Level Architecture

The base is a Tauri desktop app: a Rust core (audio capture, STT, persistence, LLM calls, commands) with a web frontend. Our additions attach at five existing seams:

- **Audio pipeline** → PCM tap feeds the speaker re-ID module (F1).
- **Database / repository layer** → new tables for speakers, profiles/facts, calendar-event links, the embedding index, and meeting series + ledger (F1, F2, F4, F7, F9).
- **Notifications / tray** → calendar-triggered record prompt (F5).
- **Summary prompt assembly** → the `SummaryContext` injection point (F2, F3, F6, F9's ledger, and the assembly stage).
- **Provider layer** → MCP extensibility (F8).

New capability lives in new modules, new DB tables, and new Tauri commands. Existing fork files are touched only at minimal registration points (command registry, navigation, settings). This is the core discipline that keeps maintenance cheap (Section 8).

---

## 7. Data Model (high level)

New persistent structures, all local SQLite unless noted:

- **speaker** — stable identity for a recognized voice: id, voice embedding/centroid, enrollment state, link to a person.
- **person / owner_profile** — authored identity (name, role, organization, domain). Owner profile stored in settings.
- **profile_fact** — inferred facts: person ref, fact text, source meeting + segment, timestamp, self-reported vs. attributed flag, confidence, superseded-by ref.
- **calendar_event (cache) + meeting↔event link** — event metadata and attendee list, linked to the produced meeting record.
- **template** — theme templates registered alongside the existing built-ins.
- **transcript segment** — extended with a `speaker_id` foreign key.
- **embedding index** — transcript-chunk vectors for F7 (may live in a dedicated store).
- **meeting_series / series_member / series_ledger** — a series groups recurring instances of the same meeting (keyed on the EventKit recurring-event identifier, with a title-based fallback); members link meetings to their series; the ledger holds the capped running memory (open items with carried status, decisions, recurring themes, per-person threads) read into and written back from summary assembly (F9).

Detailed schemas are deferred to design; the shape above is what the features require.

---

## 8. Maintenance Model

The base is an actively developed fork of an actively developed upstream. The goal is to keep pulling their improvements (the recent work is exactly in our areas of interest — recording robustness, transcript storage, VAD correctness) without merge pain.

- **Two remotes.** Track both `meetily_improved` and Zackriya upstream. Rebase/merge selectively on a defined cadence rather than continuously.
- **Additive-only architecture.** Because our features are new modules, new tables, and new commands — with edits to their files confined to registration points — our diff against the base stays small and rebases stay low-friction. Editing their files in place is the thing that turns every rebase into a conflict; avoid it.
- **Match their test discipline.** The fork ships unit tests for engine changes. New modules get the same, so a rebase that breaks an assumption fails loudly instead of silently.
- **Inherited cruft, deferred.** The tree carries two parallel audio stacks (`audio/` and `audio_v2/`) and several `*_old` files. These exist in upstream too, so they're not the fork's doing. Resolve which audio path is live before building on it (Section 9), but don't rewrite it — that would inflate the rebase surface.
- **Model-license tracking.** Record the license of any model weights bundled or shipped. Irrelevant for private local use today; relevant the moment distribution scope changes.

---

## 9. Open Questions & Discovery

Resolve before or during Phase 0:

1. **Which audio stack is live** — trace the app entry point to determine whether `audio/` or `audio_v2/` is wired, since F1 taps that path.
2. **The PCM seam** — locate where decoded audio exists alongside transcription so the re-ID module can fork a copy of the buffer without disturbing STT.
3. **System-audio channel reality** — does the capture emit one mixed stream or per-process streams? This directly sets the F1 remote-diarization ceiling. Per-process capture (newer macOS ScreenCaptureKit) would largely remove it.
4. **Re-ID module contract** — embedding model and dimension, PCM vs. self-decode, per-segment latency, and confirm the enroll-gate behavior.
5. **Distribution scope** — personal-only vs. shipped. Determines the EventKit/Contacts/mic/system-audio entitlement and notarization burden.
6. **Upstream merge-base and rebase cadence** — establish once the remotes are set; sets how often to pull upstream.
7. **Existing query implementation** — how the base's current recall works and whether it already persists any index, to know F7's true starting point.

Standing risks to manage: the remote-diarization ceiling (F1), profile quality decay and misattribution (F2), prompt bloat/bias from over-rich context (F3/assembly), and recording consent (F5).

---

## 10. Suggested Phasing

Ordered to front-load low-risk value and defer the hard, uncertain work until the seams that de-risk it exist.

- **Phase 0 — Foundation.** Fork, set both remotes, resolve the discovery questions, confirm the live audio path and PCM seam.
- **Phase 1 — Cheap, high-value, low-risk.** Owner context (F3), theme templates authoring + manual selection (F6), queryable store with persistent index (F7), MCP server (F8). All extend existing systems.
- **Phase 2 — Calendar.** EventKit integration (F4) and the record prompt (F5). Unlocks the attendee prior and the call-type signal.
- **Phase 3 — Identity.** Port and integrate the speaker re-ID module (F1); build person profiles with the two-tier + provenance model (F2).
- **Phase 4 — Unification.** Assemble the `SummaryContext` stage and enable auto template selection, now that calendar attendees and speaker counts are available to drive both. Group recurring meetings into series and thread the series ledger through the same assembly stage (F9), now that calendar detection (F4) can key the grouping and the injection point exists.

The hardest and most uncertain work (F1, F2) lands last, after the calendar and call-type signals that constrain and strengthen it are already in place.
