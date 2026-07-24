# Custom Vocabulary / Glossary

**Status:** PLAN (not implemented). Author: swift-architect, 2026-07-23.
**Phase:** Phase 4 (remaining UI nativization) — net-new Swift capability, no Rust counterpart.

---

## 0. Verification pass (every claim below re-checked against the tree, 2026-07-23)

| Claim | Verified at |
|---|---|
| `AnalysisContext` is a `final public class : Sendable` with `contextualStrings: [ContextualStringsTag: [String]]` (get/set) and a nested `ContextualStringsTag` with a single built-in `.general` | `$(xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface:467`, `:469`, `:477-483` |
| `SpeechAnalyzer.setContext(_:) async throws` on the actor | same file `:232` (and `var context: AnalysisContext { get async }` at `:229`) |
| Context-carrying inits exist: `init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)` and `init(inputAudioFile:modules:options:analysisContext:finishAfterFile:volatileRangeChangedHandler:) async throws` | same file `:209`, `:329` |
| The **plain** `init(modules:options:)` we use today takes **no** `analysisContext` | same file `:208` |
| Sole live STT provider builds `SpeechTranscriber(transcriptionOptions: [])` + `SpeechAnalyzer(modules: [transcriber])` with no context — **twice** (file path and live path) | `AriKit/Sources/AriKit/Engine/STT/SpeechTranscriberProvider.swift:125-131` and `:244-250` |
| `TranscriptionProvider` protocol has no vocabulary parameter; two entrypoints | `AriKit/Sources/AriKit/Engine/STT/TranscriptionProvider.swift:25`, `:44`, `:51-54` |
| Provider is a `Sendable` struct whose seams are injected `@Sendable` closures, with a real `init()` and a test-only `init(isAvailableCheck:supportedLocale:installedLocalesCheck:)` | `SpeechTranscriberProvider.swift:32-65` |
| Provider construction sites (both would need the new dependency): live capture service; file-import session | `Ari/Capture/SpeechLiveTranscriptionService.swift:22`; `Ari/App/AppEnvironment.swift:258` |
| Downstream call sites of the two transcribe methods | `AriKit/Sources/AriViewModels/Recording/RecordingSession.swift:361` (via `LiveTranscriptionService.transcribe(windows:language:)`, `AriViewModels/Recording/LiveTranscriptionService.swift:24-26`); `AriKit/Sources/AriViewModels/MeetingImportSession.swift:144` |
| Summary context block seam + its three existing sub-appenders | `AriKit/Sources/AriKit/Engine/Summary/SummaryContextAssembler.swift:50` (`contextBlock(for:)`), `:120` (`appendCalendarEvent`), `:150` (`appendSpeakersPresent`), `:185` (`appendSeriesLedger`) |
| Flow into `<user_context>` | `AriViewModels/SummaryRunner.swift:156-157`, `SummaryRunner.swift:230` (`mergeCustomPrompt`), `AriKit/Sources/AriKit/Engine/Summary/SummaryGenerator.swift:129-132` |
| Bounding constants + reusable helpers already on the assembler | `SummaryContextAssembler.swift:37-42`, `:229`, `:244` |
| Latest registered migration is **v4**; `v1_baseline` frozen; `eraseDatabaseOnSchemaChange` off by default | `AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift:9-17`, `:25-33`, `:476-480` |
| Repository pattern to mirror (Sendable struct over `any DatabaseWriter`, `asModel()` translation, soft delete, `observeAll()` via `ValueObservation`) | `Store/Repositories/MeetingNoteRepository.swift:11-72`, `Store/Records/MeetingNoteRecord.swift:12-44` |
| Repositories exposed as `nonisolated var` on the `AppDatabase` actor | `Store/AppDatabase.swift:76-126` |
| JSON-array-in-a-TEXT-column precedent | `SchemaMigrator.swift:327` (`attendeesJson`) |
| Partial unique index API exists in the pinned GRDB | `AriKit/.build/checkouts/GRDB.swift/GRDB/QueryInterface/Schema/Database+SchemaDefinition.swift:514-531` (`create(index:on:columns:options:condition:)`) |
| Settings key space + repository + `@Observable` VM + UI group | `Store/SettingKey.swift:63-69`, `Store/Repositories/SettingsRepository.swift:13`, `AriViewModels/SettingsViewModel.swift:30-31`, `Ari/UI/Settings/SettingsIntelligenceSection.swift:94-105` |

**Two corrections to the original brief.**

1. `SettingsIntelligenceSection.swift:193-203` is the **Summary** language picker (inside `summaryGroup`, which begins at `:176`), not a Transcription one. The Transcription group (`:94-105`) contains only a status badge and a conditional detail row — there is no transcription-language picker in the UI today (`SettingsViewModel.transcriptionLanguage` at `:153` is read-only, with no setter). So the vocabulary UI is the **second** interactive control ever added to that group; there is no adjacent picker to copy.
2. The plain `SpeechAnalyzer(modules:)` init used at `SpeechTranscriberProvider.swift:131` and `:250` cannot take a context. See §3 for why `setContext(_:)` is the right seam rather than switching inits.

**Frozen-Rust check (plan principle 8):** this is **net-new**. `frontend/src-tauri/` has no vocabulary/glossary/contextual-strings feature — whisper.cpp and Parakeet-ONNX expose no phrase-biasing surface we ever wired. This is not a re-implementation of a shipped Rust feature, so the "stop and say so" condition does not apply, and there is no dual-run to perform against a Rust incumbent (principle 2's dual-run applies to ports only).

**WIP check:** this opens no second migration phase. It lands entirely inside Phase 4 alongside the open Settings-parity item; it does not touch the Phase 3 diarization D10 tail or Phase 5.5. Recommend sequencing it **after** the D10 close-out if only one thing can be in flight, since D10 is the older WIP.

---

## 1. Goal & seam

**Goal.** A user-editable dictionary of domain proper nouns. Each term optionally carries a short description, alternate spoken forms, and known mis-transcriptions. The dictionary feeds two independent consumers:

- **Recognizer biasing** — canonical terms + alternate forms become `AnalysisContext.contextualStrings[.general]`, attached to the `SpeechAnalyzer` before analysis starts, on both the file and live paths.
- **Summarizer glossary** — a terse `### Glossary` sub-section inside the existing meeting-context block, so the LLM spells names correctly and can repair residual mis-hearings in prose.

**Seam.** Two, both already cut on the Swift side:

1. STT: inside `SpeechTranscriberProvider`, between analyzer construction (`:131` / `:250`) and analysis start (`:159` / `:276`).
2. Summary: a fourth `append*` inside `SummaryContextAssembler.contextBlock(for:)` (`:50`), joining the calendar/speakers/series appenders at `:75-77`.

Neither seam has a Rust counterpart. Nothing in `frontend/src-tauri/` changes.

---

## 2. Module & surface

Everything shared lands in `AriKit`. Nothing lands in `AriKitEngineMLX` / `AriKitDiarizationFluidAudio` / `AriCapture`.

### 2.1 `AriKit/Sources/AriKit/Models/VocabularyTerm.swift` (new)

```swift
public typealias VocabularyTermID = Identifier<VocabularyTerm>

public struct VocabularyTerm: Codable, Hashable, Sendable, Identifiable {
    public var id: VocabularyTermID
    /// The canonical spelling, exactly as it should appear in a transcript. e.g. "Arivo".
    public var term: String
    /// Optional one-line gloss for the summarizer. NEVER sent to the recognizer.
    public var definition: String?
    /// Other CORRECT spoken/written forms of the same thing ("AriKit" / "Ari Kit").
    /// These ARE sent to the recognizer. See §6 for the mis-hearing trap.
    public var alternateForms: [String]
    /// Known WRONG transcriptions ("Revo" for "Arivo"). Glossary-only — never
    /// sent to the recognizer, where they would bias TOWARD the error.
    public var misheardAs: [String]
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
}
```

Named `definition`, not `description` — a stored property named `description` on a struct shadows `CustomStringConvertible.description` and makes every `"\(term)"` interpolation surprising.

### 2.2 Store

- `AriKit/Sources/AriKit/Store/Records/VocabularyTermRecord.swift` — `Codable, FetchableRecord, PersistableRecord, Sendable`, `databaseTableName = "vocabularyTerm"`, JSON-encoded array columns, `init(_:)` / `asModel()` translation. Mirrors `MeetingNoteRecord.swift:12-44` exactly.
- `AriKit/Sources/AriKit/Store/Repositories/VocabularyRepository.swift` (§4).
- `AppDatabase` gains `public nonisolated var vocabulary: VocabularyRepository` next to `settings` (`AppDatabase.swift:124-126`).

### 2.3 Engine — the pure resolver

`AriKit/Sources/AriKit/Engine/STT/VocabularyBias.swift` (new), pure, no Store, no Speech import:

```swift
public struct VocabularyBias: Sendable, Equatable {
    /// The strings handed to `AnalysisContext.contextualStrings[.general]`, in a
    /// deterministic term-major order. Never empty (see `resolve`).
    public let contextualStrings: [String]
    /// How many candidate strings were dropped to stay under `maxContextualStrings`.
    /// Surfaced honestly in Settings and logged; never silently swallowed.
    public let droppedCount: Int

    public static let maxContextualStrings = 100
    public static let maxEnabledTerms = 50
    public static let maxAlternateFormsPerTerm = 4

    /// Returns `nil` — not an empty value — when there is genuinely nothing to bias with.
    /// A `nil` result means the caller must attach NO `AnalysisContext` at all (§7).
    public static func resolve(_ terms: [VocabularyTerm]) -> VocabularyBias?
}
```

`resolve` contract, all pure and unit-testable:

1. Keep `isEnabled == true` only.
2. Trim, drop empties, case-insensitively de-duplicate across the whole candidate set.
3. **Never** include `definition` or `misheardAs` (§6 invariant).
4. Truncate `alternateForms` to `maxAlternateFormsPerTerm` per term.
5. Order **term-major**: every canonical `term` first (sorted by `term`, stable), then alternate forms in the same term order. So truncation at the ceiling always sacrifices variants before canonical spellings.
6. Truncate the joined list to `maxContextualStrings`, recording `droppedCount`.
7. Empty result → `nil`.

`AriKit/Sources/AriKit/Engine/Summary/VocabularyGlossary.swift` (new), pure:

```swift
enum VocabularyGlossary {
    static let maxDefinitionChars = 80
    /// Returns "" when there is nothing to say — never a bare `### Glossary` heading.
    static func block(for terms: [VocabularyTerm]) -> String
}
```

Rendered shape (terse — prompt bloat is a standing PRD risk):

```
### Glossary (spell these exactly)
- Arivo — the company that makes this app. Sometimes mis-transcribed as "Revo", "Arrivo".
- AriKit (also written: Ari Kit)
```

Descriptions truncated via the existing `SummaryContextAssembler.truncateChars(_:max:)` (`:244`, already `public`).

### 2.4 The STT injection — the trade-off, and the pick

Two options were considered.

**(A) Add a parameter to `TranscriptionProvider.transcribe(...)`.** Rejected. It is a protocol-wide break across both entrypoints (`TranscriptionProvider.swift:44`, `:51-54`), and it cascades: `StubTranscriptionProvider.swift:46`, `LiveTranscriptionService.swift:24-26` (a *second* protocol, in a different target), `RecordingSession.swift:361`, `MeetingImportSession.swift:144`, plus `StubTranscriptionProviderTests`, `TranscriptionErrorTests`, `SpeechTranscriberLiveStreamTests`, `MeetingImportSessionTests`. Worse than the churn: it makes vocabulary a *caller* concern, so every caller — including `AriViewModels`, which today knows nothing about vocabulary — must fetch terms and pass them. That is exactly backwards: the biasing is an implementation detail of the SpeechAnalyzer backend, and a future `WhisperKitProvider` (the protocol is deliberately kept backend-ready, `swift-migration-plan.md:46`) would need a different representation anyway.

**(B) The provider gains an injected dependency, in the file's existing closure-seam style.** **Chosen.**

```swift
public struct SpeechTranscriberProvider: TranscriptionProvider, Sendable {
    /// Injectable vocabulary seam — mirrors `isAvailableCheck` / `supportedLocale` /
    /// `installedLocalesCheck` (SpeechTranscriberProvider.swift:38-46). `nil` result =
    /// no biasing at all. Defaults to `{ nil }` so every existing construction site and
    /// test keeps today's exact behavior.
    let vocabularyBias: @Sendable () async -> VocabularyBias?

    public init(vocabularyBias: @escaping @Sendable () async -> VocabularyBias? = { nil })
}
```

Why this fits: the struct's whole design is already "a `Sendable` value with injected `@Sendable` closure seams so error paths test headlessly" (`SpeechTranscriberProvider.swift:35-52`). A closure — rather than an injected `AppDatabase`/`VocabularyRepository` — keeps `AriKit.Engine.STT` free of any Store dependency, which it has today and should keep. It keeps the struct `Sendable` with no `@unchecked`. It gives tests a one-line stub. And the default value means the change is additive: `TranscriptionErrorTests`, `SpeechTranscriberLiveStreamTests`, and `SpeechTranscriberSmokeTest` compile and pass unchanged.

The composition root wires the real source:

```swift
// Ari/App/AppEnvironment.swift, replacing the bare SpeechTranscriberProvider() at :258
let vocabularySource = VocabularySource(database: db)   // AriKit, Sendable struct
SpeechTranscriberProvider(vocabularyBias: { await vocabularySource.bias() })
```

`SpeechLiveTranscriptionService.swift:22` changes from a private `let provider = SpeechTranscriberProvider()` to an injected `let provider: SpeechTranscriberProvider`, constructed the same way in `AppEnvironment`.

`VocabularySource` (`AriKit/Sources/AriKit/Engine/STT/VocabularySource.swift`) is a thin `Sendable` struct over `AppDatabase` that reads enabled terms and calls `VocabularyBias.resolve` — best-effort, `try?`, DB failure ⇒ `nil` ⇒ unbiased transcription rather than a failed one.

### 2.5 Settings surface

- `SettingKey`: **no new keys.** The term list is the state; a redundant "vocabulary enabled" bool would be a second source of truth. "Off" is expressed as zero enabled terms.
- `AriKit/Sources/AriViewModels/VocabularyViewModel.swift` (new) — `@MainActor @Observable final class`, exposing `terms: [VocabularyTerm]`, `enabledCount: Int`, `isAtCap: Bool`, `droppedVariantCount: Int`, and `add/update/delete/setEnabled` throwing async methods over `VocabularyRepository`. Subscribes to `observeAll()`.
- `Ari/UI/Settings/SettingsVocabularySection.swift` (new) — rendered inside the existing `SettingsGroup(header: "Transcription")` at `SettingsIntelligenceSection.swift:95`, below `transcriptionDetailRow` (`:103`). A `SettingsRow("Custom vocabulary")` with a live count and an "Edit…" button opening a Marginalia sheet holding the list editor.

---

## 3. Concurrency model

- **`VocabularyRepository`** — `Sendable` struct over `any DatabaseWriter`; every method `async throws`; all I/O inside `dbWriter.read`/`.write`, off the main actor. Identical shape to `MeetingNoteRepository.swift:11-72`. No new isolation domain.
- **`VocabularyBias` / `VocabularyGlossary`** — pure `Sendable` value types and static funcs. Callable from any domain, testable with zero infrastructure.
- **`VocabularySource`** — `Sendable` struct capturing the `AppDatabase` actor (itself `Sendable`) and calling `nonisolated` repository accessors (`AppDatabase.swift:76-126`). No actor hop beyond GRDB's own.
- **`SpeechTranscriberProvider`** stays a `Sendable` struct. The new stored property is `@Sendable () async -> VocabularyBias?` — no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- **`AnalysisContext` is a reference type** (`swiftinterface:467`) declared `Sendable` with `get`/`set` properties. To avoid relying on whatever internal synchronization that implies, the provider constructs a **fresh `AnalysisContext` per transcription call**, mutates it before handing it to the analyzer, and never stores or shares it. Document this in the code comment.
- **Hot path — the load-bearing constraint.** `await vocabularyBias()` is called **exactly once per transcription**, on the STT task, *before* `analyzer.analyzeSequence(from:)` (`:159`) / `analyzer.start(inputSequence:)` (`:276`). It must **never** appear inside the per-buffer forwarding loop at `SpeechTranscriberProvider.swift:294-305`, which is the live path's throughput-critical section, nor anywhere in `AriCapture`'s audio callbacks. A DB read per audio buffer would be a defect; the acceptance suite pins the call count (§5, T-C3).
- **Freshness semantics, stated honestly.** Because the snapshot is taken once at session start, edits made in Settings *during* a recording apply to the *next* recording, not the current one. `SpeechAnalyzer.setContext(_:)` is documented `async throws` on the live actor (`:232`) and could in principle be re-issued mid-stream, but doing so mid-session is out of scope for v1: it introduces a mutable cross-actor channel into the live path for negligible benefit. The Settings UI copy must say "applies to your next recording" rather than implying live effect (No-Fake-State).

### Why `setContext(_:)` and not a context-carrying initializer

The context-carrying inits (`swiftinterface:209`, `:329`) would force restructuring both paths:

- File path would move from `SpeechAnalyzer(modules:)` + `analyzeSequence(from:)` (`:131`, `:159`) to the `async throws` `init(inputAudioFile:...)` + `start(inputAudioFile:)` (`:329-330`) — a different driving model on the *one path that passed the STT quality gate* (mean core WER 0.2345 vs Parakeet 0.2814, `swift-migration-plan.md:46`).
- Live path would have to hand the analyzer its input sequence at construction, destroying the deliberate "internal stream we own so we can signal true end-of-input" design documented at `SpeechTranscriberProvider.swift:200-206`, `:274-281`.

`setContext(_:)` is a two-line insertion at each site with no structural change. Take it.

**Failure policy for `setContext`.** It is `throws`. If it throws, log at `.error` with the real reason and **proceed unbiased** — a meeting must not fail to transcribe because a glossary could not be attached. This is not a No-Fake-State violation because nothing in the UI ever claims per-run biasing succeeded; the honest claim ("N terms will bias your next recording") is a statement about configuration, not about a completed run. Document the reasoning inline.

---

## 4. Persistence

**Single-DB-owner rule reasserted.** One `AppDatabase` per SQLite file (`AppDatabase.swift:12-13`); all access through `VocabularyRepository`. No raw SQLite handle, no `dbWriter` reference, anywhere in `Ari/UI/`, `AriViewModels`, or `Engine`.

### 4.1 Migration — `v5_vocabulary_term`

Appended after `v4_ask_message_cards` (`SchemaMigrator.swift:476-480`). **`v1_baseline` through `v4` are frozen and are not touched.** `eraseDatabaseOnSchemaChange` is not set anywhere in this change. Additive-only DDL: one `CREATE TABLE`, two `CREATE INDEX`. Existing rows in every other table are untouched by construction. The pre-migration `VACUUM INTO` backup (`Store/StoreBackup.swift`, per `docs/plans/robust-migration-and-backup.md`) runs ahead of the migrator as it already does.

```swift
migrator.registerMigration("v5_vocabulary_term") { db in
    try db.create(table: "vocabularyTerm") { t in
        t.primaryKey("id", .text)
        t.column("term", .text).notNull()
        // Case/whitespace-folded form, for duplicate detection only. Never displayed.
        t.column("normalizedTerm", .text).notNull()
        t.column("definition", .text)
        // JSON arrays — mirrors calendarEvent.attendeesJson (SchemaMigrator.swift:327).
        t.column("alternateFormsJson", .text)
        t.column("misheardAsJson", .text)
        t.column("isEnabled", .boolean).notNull().defaults(to: true)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        // User-authored content → tombstones, sync-aware-but-off (plan principle 5).
        t.column("isDeleted", .boolean).notNull().defaults(to: false)
        t.column("deletedAt", .datetime)
    }

    // Partial unique index so a soft-deleted term can be re-added later.
    // API verified: Database+SchemaDefinition.swift:514-531.
    try db.create(
        index: "index_vocabularyTerm_on_normalizedTerm",
        on: "vocabularyTerm",
        columns: ["normalizedTerm"],
        options: .unique,
        condition: Column("isDeleted") == false
    )

    try db.create(
        index: "index_vocabularyTerm_on_isEnabled",
        on: "vocabularyTerm",
        columns: ["isEnabled"]
    )
}
```

No foreign keys — vocabulary is global, not per-meeting.

### 4.2 `VocabularyRepository`

```swift
public struct VocabularyRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDisabled: Bool = true) async throws -> [VocabularyTerm]
    public func enabledTerms() async throws -> [VocabularyTerm]   // ORDER BY term COLLATE NOCASE
    public func find(_ id: VocabularyTermID) async throws -> VocabularyTerm?
    public func enabledCount() async throws -> Int

    /// Insert-or-update. Throws `VocabularyError.duplicateTerm(String)` on a normalized
    /// collision with a live row, and `.capExceeded(limit:)` when enabling would push
    /// the enabled count past `VocabularyBias.maxEnabledTerms`. Both checks run INSIDE
    /// the same write transaction as the save — a UI-only guard would race.
    public func upsert(_ term: VocabularyTerm) async throws

    public func setEnabled(_ isEnabled: Bool, for id: VocabularyTermID) async throws
    public func softDelete(_ id: VocabularyTermID, at date: Date) async throws
    public func observeAll() -> AsyncStream<[VocabularyTerm]>
}

public enum VocabularyError: Error, Sendable, Equatable {
    case duplicateTerm(String)
    case capExceeded(limit: Int)
    case emptyTerm
}
```

Normalization for `normalizedTerm`: trim, collapse internal whitespace, `lowercased(with: Locale(identifier: "en_US_POSIX"))`, apply `.diacriticInsensitive` folding. Pure static func on the record, unit-tested independently of the DB.

---

## 5. Acceptance tests (Swift Testing, written first)

No dual-run against a Rust incumbent — there is none (§1). No S1–S4 spike gate applies; the relevant gate (S2, SpeechTranscriber) already passed and this change does not alter the decode path, only its context.

### Store — `AriKitTests/Store/VocabularyRepositoryTests.swift`

- **T-S1 `migrationIsAdditiveAndPreservesExistingRows`** — build an in-memory DB with a migrator truncated at `v4`, insert a meeting + transcript + a `setting` row, then migrate with the full `v5` migrator against the *same* writer; assert every pre-existing row survives byte-identical and `vocabularyTerm` now exists. Follows the existing `MigrationSafetyTests` two-migrator pattern (the module-internal `AppDatabase.init(_:migrator:)` seam, `AppDatabase.swift:42-45`).
- **T-S2 `v1BaselineAndV2ThroughV4AreUnmodified`** — assert `SchemaMigrator.migrator().appliedIdentifiers`-equivalent ordering ends `[..., "v4_ask_message_cards", "v5_vocabulary_term"]` and that the pre-v5 identifiers set is exactly the historical one. Guards against an in-place edit to a frozen migration.
- **T-S3 `duplicateNormalizedTermIsRejected`** — "Arivo", " arivo ", "ARIVO" all collide; the second `upsert` throws `.duplicateTerm`.
- **T-S4 `softDeletedTermFreesItsName`** — soft-delete "Arivo", re-add "Arivo", succeeds (proves the partial index condition).
- **T-S5 `enablingPastTheCapThrows`** — with `maxEnabledTerms` already enabled, enabling one more throws `.capExceeded(limit: 50)` and **no row is mutated**.
- **T-S6 `roundTripPreservesArrays`** — `alternateForms` / `misheardAs` survive JSON encode/decode, including empty and unicode.
- **T-S7 `observeAllEmitsOnChange`**.

### Bias resolver — `AriKitTests/Engine/STT/VocabularyBiasTests.swift`

- **T-B1 `emptyVocabularyResolvesToNil`** — `resolve([])` and `resolve(allDisabled)` both return `nil`, **not** an empty `VocabularyBias`. This is the empty-state invariant's first half.
- **T-B2 `definitionNeverReachesContextualStrings`** — a term with a distinctive definition string; assert that string appears in no element of `contextualStrings`. **Load-bearing invariant.**
- **T-B3 `misheardAsNeverReachesContextualStrings`** — same, for `misheardAs`. **Load-bearing invariant** (§6).
- **T-B4 `capIsEnforcedAndReported`** — feed enough terms/variants to exceed `maxContextualStrings`; assert `contextualStrings.count == 100` and `droppedCount == overflow`, exactly.
- **T-B5 `truncationSacrificesVariantsBeforeCanonicalTerms`** — every canonical `term` is present even when the cap bites.
- **T-B6 `resolutionIsDeterministic`** — the same input in shuffled order produces identical output (term-major sort).
- **T-B7 `caseInsensitiveDuplicatesCollapse`**; **T-B8 `blankAndWhitespaceOnlyEntriesDropped`**; **T-B9 `alternateFormsAreCappedPerTerm`**.

### Provider wiring — `AriKitTests/Engine/STT/SpeechTranscriberVocabularyTests.swift`

- **T-C1 `nilBiasAttachesNoContext`** — with the default `{ nil }` seam, the provider must not construct an `AnalysisContext` or call `setContext`. Asserted structurally by a spy seam (the plan adds an internal `contextApplied` test hook rather than reaching into Speech), plus the behavioral proof that all existing `TranscriptionErrorTests` / `SpeechTranscriberLiveStreamTests` still pass unchanged.
- **T-C2 `biasIsFetchedExactlyOncePerTranscription`** — a counting seam; assert `1` after a full run, on both the file and live paths.
- **T-C3 `biasIsNotFetchedPerAudioBuffer`** — drive the live path with ≥50 buffers; assert the counter is still `1`. This is the hot-path guard.
- **T-C4 `vocabularyFetchFailureDoesNotFailTranscription`** — a seam that returns `nil` after an internal error still yields a normal transcript.
- **T-C5 `providerRemainsSendable`** — extend the existing `STTSendableInventoryTests.swift:25` inventory to the new initializer.

### Glossary — `AriKitTests/Engine/Summary/VocabularyGlossaryTests.swift`

- **T-G1 `emptyVocabularyEmitsNoHeading`** — `block(for: [])` == `""`, and a `contextBlock(for:)` run on a DB with zero terms contains no `### Glossary` substring. Empty-state invariant's second half.
- **T-G2 `disabledTermsAreExcluded`**.
- **T-G3 `definitionsAreTruncated`** — a 500-char definition renders ≤ `maxDefinitionChars` + ellipsis, via `SummaryContextAssembler.truncateChars`.
- **T-G4 `misheardFormsAppearInGlossary`** — the one place `misheardAs` is *supposed* to surface.
- **T-G5 `glossaryIsBoundedOverall`** — with `maxEnabledTerms` maximal terms at maximal definitions, the rendered block is under a stated character ceiling (assert a concrete number so prompt growth is a test failure, not a surprise).

### Assembler integration — extend `AriKitTests/Engine/Summary/SummaryContextAssemblerTests.swift`

- **T-A1 `glossaryAppearsAfterSeriesLedger`** — ordering is stable and deterministic.
- **T-A2 `vocabularyAloneDoesNotForceABlock`** — the existing guard at `SummaryContextAssembler.swift:55` returns `""` when there is no owner and no participants. Decide and pin: **vocabulary alone must not open a context block** (keeping the existing guard untouched), because a glossary without any meeting context is not worth a header. Pin this as a test so a later refactor doesn't silently change it.
- **T-A3 `existingBlocksAreByteIdenticalWithZeroTerms`** — snapshot the current output of `contextBlock(for:)` for a fixture meeting before and after this change; require exact equality. This is the strongest form of the "empty vocabulary changes nothing" invariant.

### View model — `AriViewModelsTests/VocabularyViewModelTests.swift`

- **T-V1 `capIsSurfacedHonestly`** — at the cap, `isAtCap == true` and adding surfaces the real `.capExceeded` error rather than silently no-op'ing.
- **T-V2 `droppedVariantCountIsReal`** — when `VocabularyBias.droppedCount > 0`, the VM exposes that exact number (No-Fake-State: the UI states a true number or says nothing).
- **T-V3 `deleteIsSoftAndListRefreshes`**.

---

## 6. Invariants preserved

- **No-Fake-State.** (a) The cap is enforced at the write boundary and the UI reports the real count ("38 of 50 terms enabled"), never accepting a 51st term and silently ignoring it. (b) When the derived `contextualStrings` list is truncated at 100, the exact `droppedCount` is surfaced, not hidden. (c) Settings copy says vocabulary "applies to your next recording," matching the actual once-per-session snapshot semantics (§3) rather than implying live effect. (d) A `setContext` failure degrades to unbiased transcription and logs the real reason; nothing claims success. (e) Zero terms produces *nothing* — no `AnalysisContext`, no `### Glossary` heading (T-B1, T-G1, T-A3).
- **The mis-hearing trap — a real correctness invariant, not just hygiene.** Feeding an observed mis-transcription ("Revo") into `contextualStrings` biases the decoder *toward* the error. Enforced structurally: `misheardAs` is a separate field that the resolver is forbidden from reading, pinned by T-B3. The UI labels the two fields distinctly ("Also said as" vs "Sometimes mis-transcribed as") so the user cannot poison the decoder by filling in the obvious box.
- **Recall safety shell.** Untouched. Vocabulary never enters `AriKit/Sources/AriKit/Recall/`; the loopback-only / bounded-context / never-invents-citations shell has no new input. Explicit non-goal: do not add glossary terms to recall query expansion in this feature.
- **Consent-before-record.** Untouched. No new capture, no new permission, no new TCC surface.
- **Citation integrity.** Because alias→canonical rewriting is out of scope (§7), the persisted transcript remains the exact recognizer output, so `WordTiming` offsets (`TranscriptionProvider.swift:103-115`) and `SummaryCitations.applyCitations(_:sourceTranscript:)` (`SummaryGenerator.swift:141`) keep matching against unmodified source text.
- **Single DB owner.** One new repository, registered on `AppDatabase`; no second writer, no raw handle in feature code.
- **Frozen `v1_baseline`.** New `v5` only; `eraseDatabaseOnSchemaChange` untouched; T-S1/T-S2 make both machine-checked.

---

## 7. Scope decision: alias→canonical post-hoc transcript correction is **OUT** for v1

Reasons, in order of weight:

1. **It edits evidence.** The transcript is the source-of-truth record the whole app cites into. A string substitution after the fact makes the stored transcript diverge from what the recognizer actually produced, with no provenance column to record that an edit happened. That is the same class of problem the No-Fake-State rule exists to prevent.
2. **It breaks word timings.** `TranscriptionSegment.words` carries per-word `startSec`/`endSec` (`TranscriptionProvider.swift:103-115`). Replacing "Revo" (one word) with "Arivo" is benign; replacing "a river" (two words) with "Arivo" (one) invalidates the mapping, and the referenced-moments UI and `[MM:SS]` citation chips both ride on it.
3. **It is unmeasured.** We have no error-rate baseline for domain proper nouns. Shipping biasing + the LLM glossary first gives us that measurement cheaply — and the LLM glossary already fixes the *user-visible* symptom (a summary that says "Revo") without touching the transcript at all.
4. **The safe half of the benefit is already in v1.** `misheardAs` reaches the summarizer, which can normalize prose. That covers the reported pain with none of the above risk.

Revisit after v1 ships with a measured hit rate on a fixture set. If it comes back, the right shape is a *derived display layer* (render canonical, store raw) rather than a destructive rewrite.

---

## 8. Sequencing (each step independently testable)

**Step 1 — Store.** `VocabularyTerm` model, `VocabularyTermRecord`, `v5_vocabulary_term` migration, `VocabularyRepository`, `AppDatabase.vocabulary`. Tests T-S1..T-S7. Ships behind no UI; nothing reads it yet. *Gate: `swift test --filter Vocabulary` green and the full `AriKit` suite unchanged in count-minus-new.*

**Step 2 — Pure resolver.** `VocabularyBias` + `VocabularyGlossary`, no wiring. Tests T-B1..T-B9, T-G1..T-G5. Zero risk — pure functions.

**Step 3 — STT wiring.** `VocabularySource`; the `vocabularyBias` seam on `SpeechTranscriberProvider` (defaulted, so existing tests are untouched); `setContext(_:)` insertion on both paths; `AppEnvironment.swift:258` and `SpeechLiveTranscriptionService.swift:22` updated to inject. Tests T-C1..T-C5. *Gate: `SpeechTranscriberSmokeTest` and `SpeechTranscriberLiveStreamTests` still pass unmodified — the strongest evidence the default path is unchanged.*

**Step 4 — Summary wiring.** `appendGlossary` inside `contextBlock(for:)`, after `appendSeriesLedger` (`SummaryContextAssembler.swift:77`). Tests T-A1..T-A3. *Gate: T-A3's byte-identical snapshot with zero terms.*

**Step 5 — UI.** `VocabularyViewModel` + `SettingsVocabularySection`, mounted in the existing Transcription `SettingsGroup` (`SettingsIntelligenceSection.swift:95`). Marginalia-themed from `brand/tokens.json`. Tests T-V1..T-V3. *Gate: a human pass adding "Arivo", recording a short clip, confirming the term transcribes correctly and appears in the summary.*

**Step 6 — Doc reconciliation.** Update `plans/swift-migration-plan.md` (Phase 4 list + subsystem detail-plan index) and this file's status line.

### Risks

| Risk | Mitigation |
|---|---|
| Over-biasing pulls correct common words toward jargon | Caps at §2.3 (Apple's documented ≤100-phrase guidance for the sibling `SFSpeechRecognitionRequest.contextualStrings`), 1–2-word guidance surfaced as UI hint text, and step 5's human pass. If regression appears, lower `maxEnabledTerms` — it is a single constant with a test pinned to it. |
| `AnalysisContext.contextualStrings` behaves differently from the documented legacy `SFSpeechRecognitionRequest.contextualStrings` (Apple publishes no explicit limit for the new API) | We adopt the documented sibling guidance as the conservative bar and treat the numbers as tunable constants, not contract. Step 3's gate is behavioral (existing STT suites unchanged), not numeric. |
| `setContext` throws on some locale/asset combination | Caught, logged, unbiased fallback (§3). T-C4. |
| Prompt bloat degrades summaries | T-G5 pins a hard character ceiling on the glossary block; descriptions truncated at 80 chars. |
| Two provider construction sites drift | Step 3 changes both in one commit; `AppEnvironment` becomes the sole composition root for the seam. |
| Sync (Phase 5.5) later needs this table | Tombstones + stable UUID PK + nullable columns from day one, matching the store's existing sync-aware-but-off shape. |

**Nothing here falls back to a Rust sidecar.** There is no Rust incumbent and no spike gate to miss; the fallback for any failure in step 3 is simply the current unbiased behavior, which the default `{ nil }` seam preserves exactly.

---

## 9. Decisions (settled 2026-07-23)

1. **Ship `misheardAs` in v1 — YES.** One nullable column added at table-creation time, never touches the decoder (pinned by T-B3), and it is the thing that fixes the reported "Revo" symptom in the visible artifact.
2. **Cap values — accepted as proposed:** `maxEnabledTerms = 50`, `maxContextualStrings = 100`, `maxAlternateFormsPerTerm = 4`. 100 is Apple's documented ceiling for the legacy sibling API; 50 keeps the glossary prompt bounded too. All three are single constants with tests pinned to them — tune after measurement, not before.
3. **Vocabulary alone must not open a meeting-context block — accepted** (T-A2). The `owner != nil || !participants.isEmpty` guard at `SummaryContextAssembler.swift:55` stays untouched.
4. **WIP — clear.** Diarization D10 is **done** (confirmed in use, 2026-07-23), so there is no competing work in flight. Vocabulary is the active Phase 4 feature; proceed through steps 1–6 in order.

---

## References

- [Apple — `SFSpeechRecognitionRequest.contextualStrings`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings) (the legacy sibling API whose documented ≤100-phrase guidance we adopt as the conservative bar)
