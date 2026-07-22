# AriKit Diarization + Speaker Re-ID (Phase 3.5)

**Plan:** `docs/plans/arikit-diarization.md`
**Phase:** Swift migration Phase 3, step 5 (`plans/swift-migration-plan.md:184`) — the last, hardest engine port, deliberately late.
**Status:** IMPLEMENTED D1–D9b (2026-07-21) — all slices landed with per-slice review gates + a MEDIUM-findings sweep; AriKit suite green (777 tests / 119 suites), Ari app builds. **Post-landing polish (same evening, from live end-to-end use):** item-driven sheet presentation (fixed a first-click stale-state race that rendered the sheet's fallback on a healthy meeting), per-speaker **evidence snippets** (`SpeakerSamples` port of the web `speaker-samples.ts`: longest-lines-then-chronological, 2 shown per row / ≤5 in assign; clip-bounded playback via `AudioPlayerController.playClip` AVPlayer boundary observer), **pushed two-column assign view** replacing the modal-on-modal, painted sheet backgrounds removed (liquid-glass rule 45), and `MarginaliaButtonStyle` gained disabled-state rendering (previously every disabled button drew fully active — the cause of two "dead button" reports). **Open: D10** (entry-gate `.upperBound` band sweep + full stamp-accuracy gate + matcher calibration), the real two-voice fixture for the opt-in D7 integration test, and the §8 human-gate checklist (S3 formal close). AutoConfirm ships as designed but is not calibration-validated until D10 (§9 R3).
**Rust incumbent (frozen baseline):** `ari-engine/src/diarization/` (`postprocess.rs`, `matching.rs`, `tuning.rs`, `commands.rs`, `voiceprint.rs`, `engine.rs`) + the `diarize-helper` sherpa-onnx sidecar.
**Spike evidence:** S3 conditional-GO (`plans/swift-migration-plan.md:102`), FluidAudio 0.15.5 offline pipeline validated in `spikes/fluidaudio-s3/`; tuned recipe + thresholds in `plans/diarization-production-plan.md:30,53-57`.

---

## 1. Goal, scope, non-goals

### Goal

Port diarization + cross-meeting speaker re-ID to Swift: FluidAudio (CoreML pyannote community-1, **offline** `OfflineDiarizerManager`) replaces the sherpa-onnx `diarize-helper` path; the tuned Rust post-process recipe, matcher, and stamping rules port as **pure Swift modules with the Rust unit suite ported first**; results persist through the existing GRDB store (`speaker` / `speakerSegment` / `transcript.speakerId`, all already in `SchemaMigrator.swift:76-134`); a MeetingDetail "Identify speakers" flow surfaces labels with confirm-before-enroll person assignment.

This lands on the **target (Swift) side of the cut seam**: the Swift store already owns these tables and the native app already renders `speakerId → name` (`Ari/UI/Components/TranscriptSegmentRow.swift:29-36`). No Rust work is planned; the frozen Rust app is the parity baseline only.

### The S3-mandated design requirement (non-negotiable)

FluidAudio at **auto speaker count collapses multi-speaker mixed audio to one speaker** (stamp_acc 0.33 / 0.14 — disqualifying; `swift-migration-plan.md:102`). Every production run MUST be driven by a **speaker-count hint** into `config.clustering.numSpeakers` / `minSpeakers` / `maxSpeakers`. (2026-07-22 update: EventKit S7 **is now live** — synced `calendarEvent` rows + auto/manual meeting links feed `StoredCalendarHintProvider` with real data, exactly through the seam below, zero code change needed. The original hint sources remain as fallbacks.) The hint sources are:

1. **User-entered count** in the identify-speakers UI (primary; always available) — see §6 for the two explicit modes (exact vs. uncertain/at-most) this must offer.
2. **Legacy-imported calendar rows** — `CalendarEventRepository.forMeeting(_:)` → `CalendarEvent.attendees.count` (real persisted data from the Rust app's calendar cache; `AriKit/Sources/AriKit/Models/CalendarEvent.swift:81`), preferred against the meeting's linked-participant count when available (§2.6) — used to **prefill** the UI field, never to silently force K (invitee count ≠ speaker count; `plans/diarization-production-plan.md:37`).

A hint is still always required end-to-end (per S3's non-negotiable) — `.automatic` never reaches the production path — but *uncertainty* about the count must map to a bounded range (`.upperBound`), never be forced into a false-precision `.exact` assertion (H2; see §6 for the two-mode UI).

The seam is a `SpeakerCountHintProviding` protocol so live EventKit (S7) slots in later without touching the diarization pipeline.

### Non-goals (explicitly deferred)

- **Mobile / iOS diarization** — excluded by design (`swift-migration-plan.md:85`); the FluidAudio target is macOS-only.
- **Streaming / live diarization** — offline pipeline only; FluidAudio's streaming modes are far worse (38–53% DER, `swift-migration-plan.md:97`). Diarization runs post-meeting on the saved file.
- **Sherpa sidecar deletion** — `diarize-helper` stays on disk and callable (the frozen Rust app still uses it). This plan must merely **not preclude** invoking it; no Swift bridge to it is built. Deletion happens at Phase-3 exit after parity confirmation.
- **Split-track (mic/system) capture dependency** — mixed single-stream audio is a first-class input (`diarization-production-plan.md:44-46`); owner identification for imports comes from voiceprint matching, not a mic track. Split-track enhancement is out of scope.
- **Owner voiceprint bootstrap from live capture** — the owner enroll path is confirm-driven like everyone else in this phase; a dedicated "record your voiceprint" onboarding flow is a later slice.
- **Retroactive relabel across other meetings** (Rust `list_provisional_for_relabel`) — deferred to a follow-on plan; schema supports it. (B1: a minimal *same-meeting* merge-to-canonical on confirm is now **in scope** — see §2.7/§3 — this non-goal narrows to the cross-meeting retroactive relabel scan only.)
- **Voiceprint identicon UI** (Rust `voiceprint.rs`, 10 tests — the voice-ring identicon feature) — deferred as a named non-goal; the schema keeps the underlying data, no Swift port lands in this plan (parity-M2/swift-M3).
- **Summary-prompt speaker-name consumer** (Rust `labeling.rs`) — the UI-facing half (speaker → display name for reading the transcript) is partially subsumed by `MeetingDetailViewModel.resolveSpeakerNames` (D9a); feeding resolved speaker names into the *summarization prompt* is explicitly deferred to the summary-pipeline follow-on plan (parity-M2/swift-M3).
- **Runtime `diarization-tuning.json` calibration-loop knob** — Rust's edit-JSON-and-rerun loop (the `tuning.rs` file-parsing tests) is deliberately dropped, not ported; D10's rig-sweep-and-record-in-plan-doc calibration workflow supersedes it (parity-M2/swift-M3).

---

## 2. Module boundaries + public surface

### 2.1 Target layout (mirrors the `AriKitEngineMLX` isolation recipe, `AriKit/Package.swift:139-176`)

| Target | Depends on | Language mode | Contents |
|---|---|---|---|
| `AriKit` (existing) | GRDB only | `.v6` | `Engine/Diarization/` — protocol, types, pure post-process, matcher, stamper, hint types, orchestration actor. **Zero FluidAudio dependency.** |
| **`AriKitDiarizationFluidAudio`** (new target + library product) | `AriKit`, `FluidAudio` (exact `0.15.5`) | `.v6` intended; `.v5` pin allowed as a documented exception if FluidAudio's `@preconcurrency`/`nonisolated(unsafe)` internals leak (same sanctioned escape hatch as `AriKitEngineMLX`, `Package.swift:158-168`) | `FluidAudioDiarizationProvider` only. macOS-only in practice (`#if os(macOS)` in source). |
| `AriCapture` (existing) | AriKit | `.v6` | `DiarizationAudioLoader` — AVFoundation decode + resample **to 16 kHz mono** (new; `Resampler.swift` today only targets 48 kHz — a distinct converter path, not a change to the capture pipeline). |
| `AriViewModels` (existing) | AriKit | `.v6` | `SpeakerIdentificationViewModel` (`@Observable`). |
| `Ari` app target | all | — | SwiftUI screens; injects the FluidAudio provider via closure at composition root (D9b establishes this pattern — see §5). |

Dependency direction is one-way: core `AriKit` never imports FluidAudio; `swift build`/`swift test AriKit` stays headless and model-free.

### 2.2 Seam types + provider protocol (core AriKit, `Engine/Diarization/DiarizationProvider.swift`)

```swift
/// A within-meeting cluster produced by a diarizer run. Centroid is L2-normalized f32.
public struct DiarizationCluster: Sendable, Equatable {
    public var key: String            // e.g. "S1" (FluidAudio) / "spk_0" (sherpa) — opaque
    public var centroid: [Float]
    public var speechSecs: Double
}

public struct DiarizedSegment: Sendable, Equatable {
    public var clusterKey: String
    public var startTime: Double      // recording-relative seconds
    public var endTime: Double
}

public struct DiarizationOutput: Sendable {
    public var segments: [DiarizedSegment]
    public var clusters: [DiarizationCluster]
    public var embeddingModel: String // provider-stamped space id, e.g. "fluidaudio-community-1"
    public var dim: Int
}

/// The S3-mandated count hint. `.automatic` exists for the eval rig only — the
/// production path never passes it (DiarizationService rejects it; see §7 invariant I4).
public enum SpeakerCountHint: Sendable, Equatable {
    case exact(Int)          // user-asserted room size ("exactly N"); clamped 1...20 (Rust FIXED_SPEAKER_MIN/MAX)
    case upperBound(Int)     // uncertain count ("not sure / at most N", or a calendar/participant-derived
                              // prefill the user left untouched); clamped 2...12; maps to min=1, max=N
                              // (H3/swift-M1: the Rust calendar prior floors at 1, tuning.rs:30 — a
                              // floor of 2 would silently force a split on solo-speaker audio; the
                              // exact min/max mapping is pinned by the D10 entry-gate sweep, §5/§9 R4)
    case automatic
}

public protocol DiarizationProvider: Sendable {
    var providerName: String { get }
    /// The embedding-space identifier all centroids from this provider live in.
    var embeddingModel: String { get }
    func isAvailable() async -> Bool
    /// Download/compile models if needed. Idempotent. Honest errors — never a fake ready state.
    func prepare() async throws
    /// samples: 16 kHz mono [-1, 1]. Never called on the capture hot path.
    func diarize(
        samples: [Float],
        hint: SpeakerCountHint,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutput
}

public enum DiarizationError: Error, Sendable {
    case modelsUnavailable(String)
    case audioUnreadable(String)
    case hintRequired            // .automatic reached the production path
    case providerFailed(String)
}
```

`AriKitDiarizationFluidAudio` supplies the sole real conformer:

```swift
#if os(macOS)
public actor FluidAudioDiarizationProvider: DiarizationProvider {
    public init()
    public let providerName = "fluidaudio-offline"
    public let embeddingModel = "fluidaudio-community-1"
    // Stores `manager: OfflineDiarizerManager?`, created lazily. prepare() creates+prepares
    // the manager once and is idempotent (a second call is a no-op once already prepared);
    // diarize() lazy-prepares if `manager` is still nil, so the protocol's honesty contract
    // ("prepare() idempotent") holds even if a caller skips the explicit prepare() step.
    // diarize(): OfflineDiarizerConfig.default; hint mapping:
    //   .exact(n)      → clustering.numSpeakers = n
    //   .upperBound(n) → clustering.minSpeakers = 1, clustering.maxSpeakers = n   (H3/swift-M1 —
    //                    floored at 1, not 2; band mapping confirmed by the D10 entry-gate sweep)
    //   .automatic     → no constraint (rig-only)
    // OfflineDiarizerManager(config:).prepareModels(); process(audio:progressCallback:)
    // → DiarizationResult.segments (speakerId/startTimeSeconds/endTimeSeconds/embedding).
    // Cluster centroid = duration-weighted mean of that speaker's segment embeddings,
    // re-L2-normalized (same weighted_mean + l2_normalize recipe as postprocess).
    //
    // Actor, not struct (swift-H1): OfflineDiarizerManager is a class holding loaded CoreML
    // models and is not Sendable. An actor is implicitly Sendable and gives the provider a
    // legitimate place to hold prepared state across prepare()/diarize() calls without
    // reaching for `@unchecked Sendable` (forbidden, §4) or re-loading models on every call.
}
#endif
```

(API surface verified against the working spike: `spikes/fluidaudio-s3/Sources/fluidaudio-s3/main.swift:259-300`, README:29-40.)

Also add a `StubDiarizationProvider` in core AriKit test support (mirrors `StubTranscriptionProvider`) returning canned outputs — every orchestration/VM test runs on it.

### 2.3 Pure post-process module (`Engine/Diarization/DiarizationPostProcess.swift`)

Faithful port of `ari-engine/src/diarization/postprocess.rs` — pure, no IO, no actor:

```swift
public struct PostProcessConfig: Sendable, Equatable {
    public var mergeThreshold: Float = 0.7       // greedy centroid post-merge cutoff
    public var floorAbsSecs: Double = 10.0       // speech-time floor, absolute
    public var floorFrac: Double = 0.02          // speech-time floor, fraction of total speech
    public var reassignMinCosine: Float = 0.5    // dissolved-cluster reassignment cutoff
    public var maxClusters: Int? = nil           // optional hard cap (hint-derived upper bound)
    public init()
}

public enum DiarizationPostProcess {
    /// applyMerge is false in forced-K (.exact hint) mode — counts already pinned; floor still runs.
    public static func run(
        segments: [DiarizedSegment],
        clusters: [DiarizationCluster],
        config: PostProcessConfig,
        applyMerge: Bool
    ) -> (segments: [DiarizedSegment], clusters: [DiarizationCluster])
}
```

Semantics identical to Rust `postprocess.rs:130-374`: greedy duration-weighted merge at cosine ≥ 0.7 → floor `max(10s, 2% of speech)` with keep-largest guard → optional cap merge → reassign dissolved clusters at cosine ≥ 0.5 else drop segments (never fabricate identity) → stable key sort.

Shared math helpers (used by post-process, matcher, and the FluidAudio centroid builder):

```swift
public enum SpeakerMath {
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float  // 0.0 on mismatch/zero/empty
    public static func weightedMean(_ a: [Float], _ wa: Double, _ b: [Float], _ wb: Double) -> [Float]
    public static func l2Normalized(_ v: [Float]) -> [Float]                  // zero stays zero, no NaN
}

public enum CentroidCodec {   // ← engine.rs:557-572; little-endian f32, partial tail ignored
    public static func data(from vector: [Float]) -> Data
    public static func vector(from data: Data) -> [Float]
}
```

### 2.4 Matcher (`Engine/Diarization/SpeakerMatcher.swift`)

Faithful port of `ari-engine/src/diarization/matching.rs`, pure:

```swift
public struct MatchConfig: Sendable, Equatable {
    public var autoThreshold: Float = 0.70
    public var suggestThreshold: Float = 0.55
    public var margin: Float = 0.08
    public var minEnrollDurationSecs: Float = 3.0
    public var minEnrollSelfSimilarity: Float = 0.60
    public static let minFoldSpeechSecs: Double = 5.0
    public static let foldWeightCapSecs: Double = 600.0
    public static let minAutoConfirmSpeechSecs: Double = 5.0
    public init()
}

public enum MatchTier: Sendable, Equatable { case autoConfirm, suggest, anonymous }
public enum MatchReason: Sendable, Equatable {
    case matched, ambiguousMargin, belowThreshold, tooShortForAutoConfirm
    case noEmbedding, noCandidates
}
public struct MatchDecision: Sendable, Equatable {
    public var tier: MatchTier
    public var reason: MatchReason
    public var speakerId: SpeakerID?
    public var score: Float
    public var eligibleToFold: Bool
}

public enum SpeakerMatcher {
    public static func match(embedding: [Float],
                             candidates: [(id: SpeakerID, centroid: [Float])],
                             config: MatchConfig) -> MatchDecision
    public static func gateAutoConfirmByDuration(_ d: MatchDecision, clusterSpeechSecs: Double,
                                                 config: MatchConfig) -> MatchDecision
    /// One-name-per-meeting: strongest cluster keeps autoConfirm; rivals demoted.
    public static func assignMeetingClusters(_ decisions: [MatchDecision],
                                             config: MatchConfig) -> [MatchDecision]
    public static func foldCentroid(stored: [Float], samples: Int, new: [Float]) -> [Float]
    public static func foldCentroidWeighted(stored: [Float], storedTotalSecs: Double,
                                            new: [Float], newSecs: Double) -> [Float]
    public static func shouldFold(storedDim: Int, new: [Float], clusterSpeechSecs: Double,
                                  matchScore: Float?, config: MatchConfig) -> Bool
    public static func isEnrollable(segmentDurationSecs: Float, selfSimilarity: Float,
                                    config: MatchConfig) -> Bool
    /// Ranked assign-picker suggestions (← Rust `speaker_match_suggestions`, commands.rs:1361-1444),
    /// pure: per-person dedupe (best-scoring voiceprint row per person), 0.3 noise floor, top-5.
    /// Ported because the D9a/D9b assign picker should rank by similarity, not just list every
    /// person (parity-M3).
    public static func rankedSuggestions(embedding: [Float],
                                         candidates: [(id: SpeakerID, personId: PersonID, centroid: [Float])],
                                         limit: Int = 5, noiseFloor: Float = 0.3)
        -> [(personId: PersonID, score: Float)]
}
```

**Constants carry over verbatim as the starting point** (0.70 / 0.55 / 0.08 / 3.0 / 0.60 / 5.0 / 600.0) but are flagged uncalibrated for the new embedding space — see §9 R3.

**Confirm-before-enroll semantics (No-Fake-State):**
- A cluster matching **no stored voiceprint** → a **provisional** `Speaker` row (`enrollmentState: .provisional`, `personId: nil`). Never auto-linked to a person. Surfaced in the UI as an unnamed speaker awaiting identification.
- `MatchTier.autoConfirm` may auto-stamp a speaker **only when the matched voiceprint is one the user previously confirmed** (`enrollmentState ∈ {.confirmed, .owner}`) — the match chain always traces to an explicit user confirmation. The candidate pool passed to `match(...)` is filtered to confirmed/owner rows in the same `embeddingModel` space; provisional rows are never match candidates. Because `confirmSpeaker` (§2.7/§3) always merges a newly-confirmed provisional into any existing same-space canonical row for that person (B1), `matchCandidates` is, **in effect, person-deduped**: a given person can have at most one confirmed/owner voiceprint row per `embeddingModel`, so the matcher's margin gate (best vs. runner-up) never has to fight two rows belonging to the same person.
- `.suggest` results are shown as suggestions ("Looks like Nia — confirm?"), never applied.

### 2.5 Stamper (`Engine/Diarization/TranscriptStamper.swift`)

Pure port of the `stamp_transcripts` rules (`ari-engine/src/diarization/commands.rs:885-955` — untested in Rust; the Swift port gets the unit suite the Rust never had):

```swift
public enum TranscriptStamper {
    /// Max-overlap stamping. Rules (parity-L1: Rust segment sources are only "system"/
    /// "microphone" — commands.rs:614,342,654 — there is no ".owner" segment source; keep
    /// that out of this doc and out of SegmentSource, §2.8):
    ///  • per transcript row, best-overlap segment tracked separately for source == .system
    ///    vs everything else (.microphone fallback pool);
    ///  • system wins whenever any system overlap exists; fallback pool only at zero system overlap
    ///    (a whole-span microphone segment can only win rows nothing else covers);
    ///  • within a pool: larger overlap wins; near-equal (ε = 1e-6) → shorter segment wins;
    ///  • segments with a nil `speakerId` are skipped entirely (parity-L2: commands.rs:919-921 —
    ///    reachable via `.setNull` on speaker delete; see D4 `segmentsWithNilSpeakerIdAreSkipped`);
    ///  • rows with no overlap or nil audio times are returned in `unstamped` — never guessed.
    public static func stamp(
        transcripts: [Transcript],
        segments: [SpeakerSegment]
    ) -> (stamps: [(transcriptId: TranscriptID, speakerId: SpeakerID)], unstamped: [TranscriptID])
}
```

### 2.6 Hint seam (`Engine/Diarization/SpeakerCountHintProviding.swift`)

```swift
public protocol SpeakerCountHintProviding: Sendable {
    /// Best available hint for a meeting, with provenance for honest UI.
    func hint(for meetingId: MeetingID) async throws -> ResolvedSpeakerHint?
}
public struct ResolvedSpeakerHint: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case calendarAttendees, userEntered }
    public var hint: SpeakerCountHint
    public var origin: Origin
}
```

Phase-3.5 conformer: `StoredCalendarHintProvider` (core AriKit) — prefers the meeting's linked-**participant** count (`meetingParticipant` rows, matching Rust's `count_participants`, `commands.rs:263`) when it is `> 0`, falling back to `CalendarEventRepository.forMeeting(_:)` attendee count when no participants are linked yet (parity-M1: this is a deliberate divergence from a pure attendee-count read — attendee lists include declines/optional invitees/rooms and can overstate the room, so participants are preferred when they exist, matching Rust's intent even though the underlying query differs from Rust's SQL join). Either source `n ≥ 2` → `.upperBound(min(n, 12))`, origin `.calendarAttendees`; else `nil`. The UI overlays a user-entered `.exact` or `.upperBound` (per H2, §6) on top. When live EventKit (S7) lands, its provider conforms to the same protocol — nothing downstream changes.

### 2.7 Orchestration (`Engine/Diarization/DiarizationService.swift`)

```swift
public protocol DiarizationAudioLoading: Sendable {
    /// Decode any AVFoundation-readable meeting file → 16 kHz mono [-1,1]. Impl in AriCapture.
    func load16kMono(from url: URL) async throws -> [Float]
}

public actor DiarizationService {
    public init(database: AppDatabase,
                provider: any DiarizationProvider,
                audioLoader: any DiarizationAudioLoading,
                matchConfig: MatchConfig = .init(),
                postProcessConfig: PostProcessConfig = .init())

    public struct RunResult: Sendable {
        public var stampedRows: Int
        public var unresolvedRows: Int
        public var speakers: [ResolvedSpeaker]   // per surviving cluster: speakerId, tier, score, speechSecs
    }

    /// Full offline pipeline for one meeting. `hint` MUST NOT be `.automatic` (throws .hintRequired).
    public func run(meetingId: MeetingID, audioURL: URL, hint: SpeakerCountHint,
                    progress: (@Sendable (DiarizationPhase, Double) -> Void)? = nil)
        async throws -> RunResult

    /// Confirm-before-enroll: link a (provisional) speaker to a person. If the person already
    /// has a confirmed/owner voiceprint in the same `embeddingModel` space, this performs a
    /// minimal merge-to-canonical (B1 — ported from Rust `speaker_assign_to_person_impl` /
    /// `merge_speaker_into`, commands.rs:1103-1229): a `shouldFold`-gated fold of the
    /// provisional's centroid into the canonical, then REPOINT the provisional's
    /// `speakerSegment` rows and `transcript.speakerId` stamps onto the canonical, then
    /// tombstone the provisional — all in one transaction (`repointSpeakerReferences(from:to:)`
    /// + tombstone, §3). If no canonical exists yet, the provisional simply becomes the
    /// canonical (assignToPerson + fold, as before). Also links meetingParticipant (.speaker).
    /// The retroactive relabel scan across OTHER meetings (Rust `list_provisional_for_relabel`)
    /// stays deferred — see §1 non-goals.
    public func confirmSpeaker(_ speakerId: SpeakerID, as personId: PersonID,
                               inMeeting meetingId: MeetingID) async throws
}

public enum DiarizationPhase: Sendable { case preparingModels, decodingAudio, diarizing, matching, stamping }
```

`run` sequence: **idempotency clear** (§3 — FATAL on failure, parity-L6) → `provider.prepare()` → `audioLoader.load16kMono` → `provider.diarize(hint:)` → `DiarizationPostProcess.run(applyMerge: hint != .exact, maxClusters: hint == .exact ? nil : hint's upper bound)` (parity-L4: under `.exact`, `maxClusters` is pinned to `nil` — Rust's Fixed mode never caps, `commands.rs:282-285` — while `.upperBound` passes its N through) → matcher vs confirmed/owner voiceprints in the same `embeddingModel` → **`assignMeetingClusters` FIRST, then `gateAutoConfirmByDuration` per cluster** (parity-L3: pinned order, matching `commands.rs:700,728` — reversing the order changes which cluster wins a same-meeting collision) → for each surviving `autoConfirm` decision that clears `shouldFold` (score ≥ auto+margin = 0.78, `matching.rs:213-217`): `foldCentroidWeighted` → `persistFold`, and `PersonRepository.addParticipant(linkSource: "speaker")` (H1 — ported from Rust `persist_clusters`, `commands.rs:754-794`; this is the run-time fold/link that makes the stored voiceprint improve every meeting, not only on a manual confirm) → persist `Speaker`(provisional for new voices) + `SpeakerSegment` rows (source `.system` for the mixed-track file — see §9 R6) → `TranscriptStamper` → batch transcript stamps → `RunResult`. All writes via repositories.

### 2.8 Model change

Extend `SegmentSource` (`AriKit/Sources/AriKit/Models/SpeakerSegment.swift:21-42`) with known cases `.system` and `.microphone` only (parity-L1: Rust segment sources are exactly these two — `"owner"` is a *cluster_key*/enrollment-state concept, not a segment source, `commands.rs:614,342,654` — `.owner` stays **out** of `SegmentSource`). The writer set grows; `.unknown` tolerance already handles old readers, and legacy-imported raw `"system"`/`"microphone"` rows upgrade from `.unknown(...)` to the new known cases on next read (swift-L2 — a named D3 test, `legacyImportedRawSourcesUpgradeToKnownCases`, covers this). Update `ImportMapping` expectation notes only if tests pinned the seed set.

---

## 3. Schema / store changes

**Zero DDL required.** `speaker`, `speakerSegment` (with `meetingId`/`speakerId` indexes), `transcript.speakerId`, `person`, `meetingParticipant`, and `calendarEvent` all exist in `v1_baseline` (`SchemaMigrator.swift:76-134, 205-217, 306-333`). Should any DDL prove necessary during implementation, it lands per the migrator's own rule (`SchemaMigrator.swift:4-15`): extend `v1_baseline` only while it remains unshipped; otherwise a new registered migration `v2_diarization` — never an edit to a shipped migration. Single-DB-owner holds: **only `AppDatabase`'s GRDB writer touches the file**; the FluidAudio target and the app never open SQLite; the frozen Rust app's DB is a separate, already-imported file (one-shot import, not shared access).

New repository methods (all on the existing structs, all via `dbWriter`, GRDB-skill patterns):

```swift
// SpeakerRepository
func forMeeting(_ meetingId: MeetingID) async throws -> [Speaker]           // closes the TODO(S6) gap
func matchCandidates(embeddingModel: String) async throws -> [Speaker]      // enrollmentState IN (confirmed, owner), not deleted
    // (parity-L5: a deliberate tightening vs Rust's plain `person_id IS NOT NULL`,
    // speaker.rs:189-196, where cross-space rows score 0 via the matcher's dim guard rather
    // than being excluded from the query; filtering by `embeddingModel` here is equivalent in
    // effect and cheaper. Also see §2.4: in effect person-deduped once B1's merge holds.)
func persistFold(_ id: SpeakerID, centroid: Data, samples: Int,
                 totalSpeechSecs: Double, at: Date) async throws            // write-only; math stays in SpeakerMatcher
func assignToPerson(_ id: SpeakerID, personId: PersonID, at: Date) async throws  // sets personId + .confirmed
/// B1 — minimal merge-to-canonical (← Rust `merge_speaker_into`, commands.rs:1180-1229), ONE
/// transaction: repoint `speakerSegment.speakerId` and `transcript.speakerId` from the
/// provisional to the canonical for this meeting, then tombstone (soft-delete) the provisional.
func repointSpeakerReferences(from provisionalId: SpeakerID, to canonicalId: SpeakerID,
                              inMeeting meetingId: MeetingID) async throws
    -> (segmentsRepointed: Int, transcriptsRepointed: Int)
/// The idempotency guard (← Rust speaker.rs:290-328), ONE transaction:
///   1. UPDATE transcript SET speakerId = NULL WHERE meetingId = ?
///   2. DELETE FROM speakerSegment WHERE meetingId = ?
///   3. soft-delete orphaned provisional speakers (personId IS NULL, .provisional,
///      no remaining segment references) — tombstone, not hard delete (sync-aware schema rule)
/// Confirmed/owner voiceprints are NEVER touched (folds are irreversible; they are the
/// cross-meeting match pool). Unlike Rust's best-effort clear (failure logged, run continues —
/// commands.rs:192-197), Swift's `clearMeetingDiarization` failure is FATAL — it throws and
/// aborts the run (parity-L6): a failed clear before a re-run risks duplicate segment/stamp
/// rows, which is worse than refusing to proceed.
func clearMeetingDiarization(_ meetingId: MeetingID) async throws
    -> (transcriptsCleared: Int, segmentsDeleted: Int, provisionalsRemoved: Int)

// SpeakerSegmentRepository
func insert(_ segments: [SpeakerSegment]) async throws                       // batch, one transaction

// TranscriptRepository
func setSpeakers(_ stamps: [(transcriptId: TranscriptID, speakerId: SpeakerID?)],
                 inMeeting meetingId: MeetingID) async throws -> Int         // batch stamp / user reassign / clear
```

`confirmSpeaker` composes `assignToPerson` + `SpeakerMatcher.shouldFold`/`foldCentroidWeighted` + `persistFold` + (when a same-space canonical already exists for the person) `repointSpeakerReferences` + tombstone (B1) + `PersonRepository.addParticipant(linkSource: "speaker")` (exists, `PersonRepository.swift:131-149` — swift-L5 citation fix) — all in one transaction.

Repository header-comment note (swift-L3): `clearMeetingDiarization` and `repointSpeakerReferences` on `SpeakerRepository` are two of the few call sites that legitimately cross into the `transcript` table from a non-`TranscriptRepository` file — precedented by Rust's own `speaker.rs:290` doing the same across tables in one transaction. Update `SpeakerRepository.swift`'s header contract comment to note the exception rather than treating it as a violation.

---

## 4. Concurrency model

- **`DiarizationService` is an actor** — serializes runs per process, owns no UI state. All heavy work (`prepare`, decode, `process`) happens inside `async` provider/loader calls off the main actor. FluidAudio internally runs segmentation/embedding on detached tasks + ANE; we add no threading around it.
- **Hot-path guarantee:** diarization is strictly **post-meeting offline**. It never subscribes to the capture pipeline, never runs while `RecordingSession` is active in this phase (the VM disables the action during recording), and shares no locks with STT. The audio hot path is untouched.
- **Sendable boundaries:** every seam type (`DiarizationOutput`, `SpeakerCountHint`, `MatchDecision`, configs) is a value type + `Sendable`. `[Float]` sample buffers cross the actor boundary by value (one ~40-min meeting at 16 kHz mono f32 ≈ 150 MB transient — acceptable for an offline job; note in impl to release promptly).
- **Progress to UI:** `@Sendable (DiarizationPhase, Double) -> Void` closure from the service, bridged in `SpeakerIdentificationViewModel` via `Task { @MainActor in ... }` hops into `@Observable` state. No Combine, no TCA.
- **No `@unchecked Sendable` in our code.** FluidAudio's own `nonisolated(unsafe)` model cache is upstream and confined to the isolated target; if the target cannot compile clean under `.v6`, pin **that target only** to `.v5` with the same documented-exception comment style as `AriKitEngineMLX` (`Package.swift:158-168`). Core AriKit stays `.v6` regardless. `FluidAudioDiarizationProvider` itself is an **actor**, not a `Sendable` struct (swift-H1), precisely so it can legitimately hold `OfflineDiarizerManager` state without reaching for `@unchecked Sendable`.

---

## 5. Implementation slices (D1–D8, D9a, D9b, D10)

Each slice lands independently with `swift build` + `swift test` green. The diarization module holds **86** Rust tests, not 94 (parity-M2/swift-M3 correction): postprocess 19, matching 36, engine 12, tuning 9, voiceprint 10, labeling 0, commands 0. Disposition of every Rust file:

| Rust file | Tests | Disposition |
|---|---|---|
| `postprocess.rs` | 19 | Ported verbatim — D1 |
| `matching.rs` | 36 | Ported (incl. the ported `speaker_match_suggestions` → `rankedSuggestions`, parity-M3) — D2 |
| `engine.rs` (codec-relevant subset) | 12 | Centroid round-trip / little-endian / partial-tail ported — D1 (`CentroidCodecTests`) |
| `tuning.rs` (clamp + default-value assertions) | 9 | Ported — D3 (clamps) / D1, D2 (defaults, invariant I9) |
| `tuning.rs` (runtime `diarization-tuning.json` file-parsing / edit-reload loop) | (subset of the 9 above) | **Deliberately dropped** — the runtime JSON-knob calibration loop has no Swift equivalent; D10's rig-sweep-and-record-in-plan-doc calibration workflow supersedes it |
| `voiceprint.rs` | 10 | **Deferred** — named non-goal (§1); the voice-ring identicon UI does not port in this plan; schema keeps the data |
| `labeling.rs` | 0 (untested in Rust) | **Partially subsumed** by `MeetingDetailViewModel.resolveSpeakerNames` (D9a) for UI display; the *summary-prompt* consumer is deferred to the summary-pipeline follow-on plan — named non-goal (§1) |
| `commands.rs` (stamping rules) | 0 (untested in Rust) | Ported as a **net-new** suite — D4 |

**D1 — Pure math + post-process.**
Files: `Engine/Diarization/SpeakerMath.swift`, `CentroidCodec.swift`, `DiarizationPostProcess.swift`, `DiarizedSegment.swift` (seam value types); tests `DiarizationPostProcessTests`, `SpeakerMathTests`, `CentroidCodecTests`.
Ports: all 19 `postprocess.rs` tests verbatim (`mergesTwoHighlySimilarClusters`, `distinctClustersDoNotMerge`, `mergeSkippedInForcedKMode`, `floorDissolvesAndReassignsToNearCluster`, `floorDropsFarDissolvedCluster`, `fractionalFloorAppliesWhenLargerThanAbs`, `floorKeepsLargestWhenAllBelow`, `emptyInputIsEmptyOutput`, `segmentsWithNoClustersPassThroughUntouched`, `singleClusterSurvivesUnchanged`, `mergeIsDurationWeightedTowardLargerCluster`, `maxClustersCapsDistinctSurvivors`, `maxClustersNoopWhenUnderCap`, `maxClustersOneCollapsesToSingle`, `threeWayMergeCollapsesSimilarGroup`, plus the 4 math tests) + cosine guards (matching tests 20–25) + centroid round-trip/little-endian/partial-tail (engine tests 75–78).

**D2 — Matcher.**
Files: `SpeakerMatcher.swift`, `MatchConfig.swift`; tests `SpeakerMatcherTests`.
Ports: the remaining 30 `matching.rs` tests (26–55): both fold functions incl. `weightedFoldCapsStoredWeightForEMA`, `shouldFold` gates, every `classify` boundary (`matchExactlyAtAutoThresholdIsAuto`, `matchAboveThresholdButAmbiguousMarginIsSuggest`, …), `assignNoDoubleAssignDemotesWeakerCluster`, duration gate, `enrollableRequiresDurationAndQuality`. Also ports `speaker_match_suggestions` (commands.rs:1361-1444) as pure `SpeakerMatcher.rankedSuggestions` — per-person dedupe, 0.3 noise floor, top-5 — with its own ported test coverage (parity-M3); D9a's assign picker consumes the ranked list above the plain full-person list.

**D3 — Provider seam + hint types + stub.**
Files: `DiarizationProvider.swift`, `SpeakerCountHint.swift`, `SpeakerCountHintProviding.swift`, `StoredCalendarHintProvider.swift`, `StubDiarizationProvider.swift`; `SegmentSource` case extension.
Tests: `SpeakerCountHintTests` (clamping 1...20 exact / 2...12 upper-bound — ports tuning test 62's clamp semantics; `.upperBound` maps to min=1/max=n per H3, pending the D10 entry-gate sweep that confirms the band), `StoredCalendarHintProviderTests` (in-memory DB: participant-count preferred over attendee-count when > 0 — parity-M1 — attendee-count fallback when no participants linked, no event/no participants → nil, 1-attendee → nil — honest absence), `SegmentSourceTests` (new `.system`/`.microphone` raw values + unknown tolerance + `legacyImportedRawSourcesUpgradeToKnownCases`, swift-L2 — previously-imported `.unknown("system")` rows decode as `.system` and enter the preferred stamping pool).

**D4 — Stamper.**
Files: `TranscriptStamper.swift`; tests `TranscriptStamperTests` (net-new suite encoding `commands.rs:885-955` rules — parity-L6 citation fix from the earlier `884-954`): `systemOverlapBeatsLargerMicrophoneOverlap`, `microphoneFallbackOnlyWhenZeroSystemOverlap`, `largerOverlapWinsWithinPool`, `nearEqualOverlapPrefersShorterSegment` (ε 1e-6), `rowsWithoutAudioTimesGoUnstamped`, `rowsWithNoOverlapGoUnstamped`, `wholeSpanMicrophoneSegmentDoesNotSweepMeeting` (parity-L1 rename — Rust has no `.owner` segment source, so this can't be an "owner" segment), `segmentsWithNilSpeakerIdAreSkipped` (parity-L2 — `commands.rs:919-921`; nils are reachable via `.setNull` on speaker delete).

**D5 — Store surface.**
Files: `SpeakerRepository.swift`, `SpeakerSegmentRepository.swift`, `TranscriptRepository.swift` additions (§3).
Tests (in-memory `AppDatabase`): `speakerForMeetingReturnsOnlyReferencedSpeakers`, `matchCandidatesFilterByStateAndModel` (provisional + wrong-space excluded), `clearMeetingDiarizationUnstampsDeletesAndTombstonesProvisionals`, `clearMeetingDiarizationNeverTouchesConfirmedOrOwner`, `clearMeetingDiarizationThrowsAndAbortsOnFailure` (parity-L6 — Swift's clear is fatal, not best-effort), `batchSegmentInsertIsTransactional`, `setSpeakersStampsAndClears`, `assignToPersonSetsConfirmed`, `repointSpeakerReferencesMovesSegmentsAndStampsThenTombstonesProvisional` (B1).

**D6 — Audio loader (AriCapture).**
Files: `AriCapture/DiarizationAudioLoader.swift` (`#if os(macOS)`, AVAudioFile/AVAudioConverter → 16 kHz mono). `Package.swift`: add `resources: [.copy("Fixtures")]` to the `AriCaptureTests` target (swift-M2 — it currently declares none) so the bundled fixture m4a resolves via `Bundle.module`.
Tests: `DiarizationAudioLoaderTests` with a small bundled fixture m4a (sample-count/rate assertions, multi-channel downmix, unreadable-file honest error).

**D7 — FluidAudio provider target.**
Files: `Package.swift` — new `AriKitDiarizationFluidAudio` target/product (`FluidAudio` exact 0.15.5 dependency) **and** a new `AriKitDiarizationFluidAudioTests` test target with its own `resources:` for fixtures (swift-M2 — neither existed in the original slice), same language-mode decision made alongside the main target (`.v6` attempted first; `.v5` documented-exception fallback per swift-L1 only if needed); `AriKitDiarizationFluidAudio/FluidAudioDiarizationProvider.swift` (an **actor**, swift-H1 — see §2.2).
Tests: `FluidAudioHintMappingTests` (pure mapping to `numSpeakers`/`min`/`max` via an extracted pure function — no model download; covers `.upperBound → min=1` per H3), `centroidBuildIsDurationWeightedAndUnit`, `prepareIsIdempotentAcrossRepeatedCalls` (swift-H1 — asserts the actor's lazy-prepare contract holds whether or not `prepare()` was called explicitly); one **manual/opt-in integration test** (`.enabled(if: env)` — requires the ~21 MB model download) running a bundled 2-voice fixture and asserting ≥2 clusters with `.exact(2)`.

**D8 — `DiarizationService` orchestration.**
Files: `DiarizationService.swift`; tests `DiarizationServiceTests` on `StubDiarizationProvider` + in-memory DB: `rerunIsIdempotent` (run twice → identical row counts/links, no orphan provisionals; centroids may drift by design on re-run — H1/I3, matching Rust's accepted non-idempotency, `commands.rs:103-109` — the test asserts row-counts/links only, with a doc comment noting centroid drift is expected), `automaticHintThrowsHintRequired`, `newVoiceCreatesProvisionalNeverAssignsPerson`, `confirmedVoiceprintAutoStampsAcrossMeetings`, `suggestTierNeverWritesPersonLink`, `postProcessSkipsMergeUnderExactHint`, `stampsPersistViaRepositoriesOnly`, `unresolvedRowsReportedHonestly`, `confirmSpeakerLinksPersonFoldsAndAddsParticipant`, `confirmSpeakerSkipsFoldBelowSpeechFloor`, `autoConfirmFoldsWhenScoreClearsAutoPlusMargin` (H1, score ≥ 0.78), `bareAutoConfirmDoesNotFold` (H1, 0.72 case, `matching.rs:734-742`), `autoConfirmLinksParticipant` (H1), `secondConfirmOfSamePersonDoesNotCreateSecondCandidate` (B1 — confirms the same person from two different meetings and asserts `matchCandidates` still returns exactly one row for that person).

**D9a — `SpeakerIdentificationViewModel`** (swift-M4/swift-L4: split out of the original single D9 slice; headless, no app-target dependency).
Files: `AriViewModels/SpeakerIdentificationViewModel.swift`; `MeetingDetailViewModel.resolveSpeakerNames` switches to `SpeakerRepository.forMeeting` (closing the TODO(S6) workaround).
Tests: `SpeakerIdentificationViewModelTests` — `honestIdleBeforeRun`, `hintPrefilledFromCalendarWithOrigin`, `runRequiresCountWhenNoHint`, `userUncertainCountMapsToUpperBoundNotExact` (H2), `progressPhasesReachUI`, `honestFailedOnProviderError`, `confirmFlowCallsServiceOnce`, `runDisabledWhileRecording`.

**D9b — SwiftUI surfaces + app composition** (swift-M4/swift-L4: the app-facing half of the original D9).
Files: `Ari/UI/MeetingDetails/IdentifySpeakersSheet.swift`, `SpeakerAssignmentRow.swift`, wiring in `MeetingDetailView`. **Link the new `AriKitDiarizationFluidAudio` library product in `Ari.xcodeproj`**; construct `DiarizationService` in `AppEnvironment` post-`bootstrap()`; thread `recordingSession` state (`AppEnvironment.swift:44`) into the VM for `runDisabledWhileRecording`. (swift-M4 correction: no file in `Ari/` today references `ProviderFactory` or `mlxClientProvider` — that injection pattern is not yet exercised anywhere in the app; D9b establishes it rather than copying an existing precedent.)
Tests: sheet/row rendering exercised against `SpeakerIdentificationViewModelTests`' fixtures; `MarginaliaTokenParityTests` coverage for the new screens (existing suite, no new logic tests — this slice is wiring, not behavior).

**D10 — Gate + calibration** (see §8).
**Entry-gate task (H3/swift-M1 — promoted from an exit check to an entry gate; runs before D9a/D9b freeze default behavior, and can start right after D7 lands):** sweep `.upperBound` mappings on the rig — (i) min=1..max=n (current default, §2.2), (ii) min=2..max=n (the original draft mapping), (iii) postprocess-cap-only / no clusterer constraint (Rust-faithful Calendar mode, `commands.rs:256-281`); add test `upperBoundOnSingleVoiceAudioYieldsOneCluster` (a single-voice fixture with a multi-invitee hint must still yield exactly 1 surviving cluster). Freeze the `.upperBound` band used by `StoredCalendarHintProvider`/`FluidAudioDiarizationProvider` only after this sweeps clean.
Remaining files: `tools/diarization-sweep/` gains a documented invocation for the Swift pipeline; a tiny CLI target (or extension of the existing spike) `arikit-diarize-rttm` that runs `FluidAudioDiarizationProvider` + `DiarizationPostProcess` + `TranscriptStamper` mapping and writes RTTMs to `hypotheses/fluidaudio-swift/<label>/`. Threshold-calibration notebook step for `MatchConfig` in the new embedding space (same/different-speaker centroid pairs from own recordings, per `diarization-production-plan.md:63`).
No app code changes; output is `results/fluidaudio-swift-<label>.json` + a plan-doc results table.

Dependency order: D1 → D2 → (D3, D4 parallel) → D5 → D6 → D7 → D8 → D9a → D9b → D10. D10's entry-gate task can start right after D7 lands (it needs only the raw provider + postprocess, not the UI) and should complete before D9a/D9b ship the `.upperBound` prefill-as-band behavior as default (H3); the rest of D10 (the full RTTM gate) runs after D9a/D9b.

---

## 6. UI slice (D9a/D9b) — Marginalia + No-Fake-State

**Entry point:** MeetingDetail gains an "Identify speakers" action (Secondary tonal button — not Primary; the view's one Primary stays with its existing role) visible when the meeting has resolvable audio (`AudioAvailability.available`) and transcripts with audio times. Disabled with honest explanation when audio is `.missing`.

**Identify-speakers sheet:**
- **Count-hint input** — two explicit modes, never one ambiguous field (H2): **"Exactly N"** (the user asserts a known room size) → `.exact(n)`; **"Not sure / at most N"** (the user's best guess, or an untouched calendar/participant-count prefill from `StoredCalendarHintProvider`) → `.upperBound(n)`. A user's *uncertain* guess must never silently become a forced exact count — the `.upperBound` path merges + floors + caps instead of pinning K. Provenance line shown when prefilled ("From calendar: 6 invited" / "From N linked participants" — real data only; no signal available → field empty, no fabricated default). Run button disabled until a hint exists in either mode (`.automatic` never reaches the service; §1).
- **Progress** — phase-labeled (`Preparing models… / Reading audio… / Separating voices… / Matching… / Labeling transcript…`) driven only by real `DiarizationPhase` callbacks. First run shows the genuine model-download state; never an indeterminate fake bar over invented steps.
- **Results** — per resolved cluster a row: speech time (real), tier badge:
  - **autoConfirm** against a previously-confirmed voiceprint → name shown, stamped, with an "undo/reassign" affordance;
  - **suggest** → "Looks like *Nia* (0.61)" with **Confirm** / **Not them** — nothing written until Confirm;
  - **anonymous/provisional** → "Unidentified speaker · 4 min" + **Assign person…** (picker ranked by `SpeakerMatcher.rankedSuggestions` — parity-M3, ported from `speaker_match_suggestions` — shown above the full `PersonRepository.all()` list, plus "New person…"). Confirm calls `DiarizationService.confirmSpeaker` — the **single structural gate** into `assignToPerson`/fold/repoint (B1), mirroring the `confirmConsent()` pattern (`RecordingSession.swift:9-11` — swift-L5 citation fix).
- **Transcript rows** keep the existing honest fallback: unresolved rows continue to render "No speaker" (`TranscriptSegmentRow.swift:32-33`) — never "Speaker 1".

**Marginalia compliance:** Shin-kai accent only for the confirm action and speaker-name chips (≤8% rule); tier badges use `MarginaliaBadge`; SF Symbols only (`person.crop.circle`, `waveform`), no emoji; sentence case; recording red never appears here (not a capture surface); tokens via `MarginaliaColor`/`Typography` — parity enforced by the existing `MarginaliaTokenParityTests`.

---

## 7. Invariants preserved (each with its enforcing test)

| # | Invariant | Enforcing test (slice) |
|---|---|---|
| I1 | **Confirm-before-enroll** — a person↔voiceprint link is only ever created by explicit user confirmation | `newVoiceCreatesProvisionalNeverAssignsPerson`, `suggestTierNeverWritesPersonLink` (D8); `confirmFlowCallsServiceOnce` (D9a) |
| I2 | **No-Fake-State** — unresolved speakers stay `nil`/"No speaker"; dropped clusters' segments omitted, never relabeled; progress reflects real phases | `floorDropsFarDissolvedCluster` (D1), `rowsWithNoOverlapGoUnstamped` (D4), `unresolvedRowsReportedHonestly` (D8), `honestIdleBeforeRun`/`honestFailedOnProviderError` (D9a) |
| I3 | **Idempotent re-run** — re-diarizing clears prior segments/stamps/orphan provisionals; confirmed/owner voiceprints never destroyed | `rerunIsIdempotent` (D8 — row-counts/links only; centroids may drift by design on re-run, matching Rust's accepted non-idempotency, `commands.rs:103-109`; H1), `clearMeetingDiarizationNeverTouchesConfirmedOrOwner` (D5) |
| I4 | **Hint-mandatory** — the production path never runs FluidAudio at auto count | `automaticHintThrowsHintRequired` (D8), `runRequiresCountWhenNoHint` (D9a) |
| I5 | **One DB owner / repositories only** — no SQLite access outside `AppDatabase` repositories; FluidAudio target is DB-free | `stampsPersistViaRepositoriesOnly` (D8) + code review gate: `AriKitDiarizationFluidAudio` has no GRDB import |
| I6 | **Consent-before-record untouched** — diarization consumes already-consented recordings; adds no capture path; disabled during recording | `runDisabledWhileRecording` (D9a); existing `RecordingSessionTests` unchanged |
| I7 | **Embedding-space integrity** — centroids never matched/folded across `embeddingModel`/`dim` boundaries | `matchCandidatesFilterByStateAndModel` (D5), `shouldFoldRejectsDimMismatch` (D2) |
| I8 | **Recall safety shell untouched** — this plan changes no recall code; its invariant suite must stay green | existing recall tests (regression check in every slice's `swift test`) |
| I9 | **Parity recipe fidelity** — thresholds 0.7 merge / max(10s, 2%) floor / 0.5 reassign / 0.70-0.55-0.08 matcher are the defaults | `PostProcessConfig`/`MatchConfig` default-value tests (D1/D2, ports tuning test 56) |
| I10 | **No voiceprint fragmentation on repeat confirm** — confirming the same person twice never creates a second match-pool candidate | `secondConfirmOfSamePersonDoesNotCreateSecondCandidate` (D8, B1) |

---

## 8. Gate plan (S3 formal close + Swift parity)

The **measuring stick is `tools/diarization-sweep/`, primary metric `stamp_accuracy`** (DER secondary), per `swift-migration-plan.md:97`.

**Automated gate (D10), run before D9b ships as default-on** (the `.upperBound` band mapping itself is frozen earlier, by D10's entry-gate task — H3/swift-M1, §5):
1. `arikit-diarize-rttm` produces `hypotheses/fluidaudio-swift/v1/<meeting-id>.rttm` for every manifest meeting, using each meeting's real hint (`.exact` from known counts).
2. `uv run --with pyannote.metrics --with numpy python3 der.py --engine fluidaudio --label swift-v1` (rig already supports arbitrary hypothesis dirs).
3. **Pass bar:** `mean stamp_accuracy(fluidaudio-swift) ≥ mean stamp_accuracy(sherpa)` on the verified subset; additionally fluidaudio-swift ≈ the spike's fluidaudio numbers (confirms the port introduced no regression vs the spike pipeline).
4. Matcher threshold calibration: same/different-speaker centroid-pair distributions in the FluidAudio space; adjust `MatchConfig` defaults if the 0.70/0.55/0.08 guesses are wrong there; record in this plan.

**Human-gate checklist (explicit; S3 formal close is blocked on item 1):**
- [ ] **Record one clean, native (non-import), in-person 3+ speaker meeting** through the Swift capture path; Paul hand-verifies every transcript row's speaker; add its id to `VERIFIED_MEETING_IDS` in `extract_reference.py` and re-extract references. (Every existing reference is sherpa-derived/circular; the two natural multi-speaker meetings are mixed imports; two others carry the 2× `audio_end_time` bug.)
- [ ] Re-run the automated gate including the new verified reference; the pass bar must hold on it.
- [ ] **TCC-free confirmation:** verify a first-run diarization inside the signed `Ari.app` triggers **no new TCC prompt** (CoreML inference + model download need none; only network for the one-time ~21 MB fetch) and that the model cache lands at `~/Library/Application Support/FluidAudio/Models/` as in the spike.
- [ ] Paul spot-checks the identify-speakers UI end-to-end on the 3+ speaker recording: hint entry → run → confirm two people → labels correct → re-run idempotent.
- [ ] Sign-off recorded in `plans/swift-migration-plan.md` S3 status (conditional-GO → CLOSED) and in this plan.

Until all boxes tick, the sherpa path in the frozen Rust app remains the fallback of record (no Swift bridge built; falling back = running the frozen app, which this plan does not preclude).

---

## 9. Risks + open questions (with recommended resolutions)

- **R1 — FluidAudio under Swift 6 strict concurrency.** Its internals use `@preconcurrency import CoreML` + `nonisolated(unsafe)`. *Update (swift-L1):* the spike (`spikes/fluidaudio-s3/Package.swift`, tools-version 6.2, no language-mode pin) already compiles FluidAudio-consuming code under the **default v6 language mode** — the earlier premise that "the spike never pinned `.v6`" was wrong; tools ≥6.0 defaults an unpinned target to v6. *Resolution:* expect `.v6` to work on the isolated target as the default outcome; keep the `.v5` documented-exception fallback (precedent: `AriKitEngineMLX`, `Package.swift:158-168`) only if it doesn't. Core AriKit unaffected either way.
- **R2 — Embedding-space break (CAM++ → community-1).** Legacy-imported voiceprints (192-dim CAM++) cannot match FluidAudio centroids — re-enrollment is required (`diarization-production-plan.md:68`). *Resolution:* keep legacy rows (history intact); matcher filters by `embeddingModel` (I7); confirmed people simply re-confirm once in the new space via the D9a/D9b flow, which now (B1) folds the fresh community-1 voiceprint into a canonical row and repoints references rather than leaving a second, competing confirmed row behind. No migration, no deletion. **Human decision:** accept the one-time re-confirmation UX (recommended: yes).
- **R3 — Matcher thresholds uncalibrated for the new space.** 0.70/0.55/0.08 were CAM++ guesses (`matching.rs` docs: "RETUNE ON REAL RECORDINGS"). *Resolution:* D10 calibration step is mandatory before autoConfirm ships enabled; until calibrated, an option is shipping D9b with autoConfirm demoted to suggest (extra safety, zero risk). Recommended: calibrate first, ship autoConfirm as designed.
- **R4 — Calendar count ≠ speaker count.** Forced K from invitee counts merged distinct people in Rust (`diarization-production-plan.md:37`). *Resolution:* calendar/participant count → `.upperBound` (min **1** / max N band — H3/swift-M1, matching Rust's calendar prior which floors at 1, `tuning.rs:30`, not 2) prefill only; `.exact` reserved for explicit user assertion (H2). The band mapping is validated on the rig as a **D10 entry-gate task**, run *before* D9a/D9b ship the prefill-as-band behavior as default — not as a post-hoc exit check (swift-M1 promoted this from exit to entry gate). If the min=1 band still over-splits solo-speaker audio, tighten further per the D10 sweep of alternatives (i)/(ii)/(iii), §5.
- **R5 — AutoConfirm vs "never auto-assign without confirmation".** Resolved in §2.4: autoConfirm only against previously user-confirmed voiceprints (the confirmation chain is real), and B1's merge-to-canonical keeps that chain from fragmenting across repeat confirms. **Human decision to ratify** — if Paul wants stricter (every meeting re-confirms), flip one flag in `DiarizationService`; tests I1/I10 cover both shapes.
- **R6 — Segment `source` on single-file native recordings.** The native recorder writes one mixed m4a, so all segments are effectively system+mic mixed; stamping's system-preference is moot until split tracks exist. *Resolution:* stamp segments `source: .system` for mixed files (matches Rust behavior on imports; keeps the stamper rules dormant-but-correct for a future split-track slice). Owner detection via voiceprint matching, not track origin.
- **R7 — First-run model download needs network.** *Resolution:* `prepare()` errors surface honestly in the UI (`honestFailedOnProviderError`); no offline fabrication. Consider pre-warming during onboarding later (out of scope).
- **R8 — Memory of full-meeting `[Float]` buffers** (~150 MB transient per 40-min meeting). *Resolution:* acceptable for an offline actor-serialized job; implementer should scope the buffer tightly. Not a blocker.
- **R9 — License.** FluidAudio SDK Apache-2.0; pyannote-derived weights **CC-BY-4.0** (attribution) — matters only if distribution widens; note carried in `product.md`. No action now.
- **R10 — WIP-limit check.** This plan touches `MeetingDetailViewModel` (speaker-name resolution) which S6 flagged as a TODO — that's closing a documented gap inside this feature's seam, not opening a second phase. EventKit (S7) is *not* pulled in; only the protocol seam anticipates it.

**Open decisions for Paul:** (a) ratify R5 autoConfirm semantics; (b) accept R2 one-time re-confirmation of known people in the new embedding space (now merge-safe per B1); (c) whether D9b ships before or after the human-verified 3+ speaker recording exists (recommended: D1–D8 and D9a land regardless; D9b can ship behind the gate with autoConfirm-as-suggest until §8 closes).
