# Onboarding / First-Run Install Flow

**Status:** proposed, not yet built. Attaches to Phase 4 ("remaining UI nativization") of
`plans/swift-migration-plan.md`, checklist item "Onboarding flow" — currently not started.
"Zero code hits for 'onboarding'" anywhere in `Ari/` or `AriKit/` (confirmed: only a stray comment
at `Ari/UI/Ask/AskOverlayHost.swift:4` mentions "onboarding" and is unrelated).

## 0. Scope call — is this a re-implementation of a frozen Rust feature?

No, with one deliberate correction. The old Rust flow (`frontend/src-tauri/src/onboarding.rs`,
`frontend/src/components/onboarding/OnboardingFlow.tsx`, `frontend/src/lib/model-tiers.ts`) was a
**4-step wizard with 3 selectable model tiers** (Express/Balanced/Demanding) driven by a RAM
threshold recommendation. That shape is explicitly **not** being ported — the product owner wants
something smaller: no tiers, no choice, just "check what's missing, download it, explain why
local matters, show hardware info informationally." This is closer to net-new UX than a port, so
it is in-scope Swift-first work, not a frozen-feature re-implementation. Principle 8 (WIP limits,
Swift-only go-forward) is respected: nothing here touches `frontend/src-tauri`.

**One explicit scope cut, flagged per the task brief's own tension:** SpeechAnalyzer/`Speech`
framework asset installation (`AssetInventory`, see §2.4) is a real "not installed yet" gap this
flow could plausibly own, but the user explicitly excluded STT from the models this flow
downloads. This plan **respects that exclusion** and leaves SpeechAnalyzer asset installation
out of scope — see §7/§9 (Risks) for why that's a live gap worth a follow-up decision, not a plan
silently expanding to cover it.

**WIP-limit note:** a few other worktrees may touch `AriKit` concurrently. None currently register
a `v2` migration, and this plan proposes **no new migration at all** (§4), so there is no
collision risk on that axis. Worth a quick diff against `Ari/UI/Settings/
SettingsIntelligenceSection.swift` before landing (adjacent surface), not a blocker to planning.

---

## 1. Goal & seam

**Goal:** on first run (or whenever something required is missing), show the user a short,
honest flow that:

1. Explains in plain Marginalia voice why the three on-device components exist and why local
   matters (privacy framing already established in `brand/BRAND.md` §1 "What stays local" —
   reuse that register, don't invent new copy tone).
2. Reports real hardware capability (RAM, and whether the machine is Apple Silicon — trivially
   true, since the whole platform floor is macOS 26/Apple Silicon per `.claude/rules/
   platform-and-deps.md`) with an honest, **non-blocking** soft warning if RAM is under a
   calibrated comfort floor for the on-device summary model.
3. Triggers download/compile of whatever is missing among: **diarization (FluidAudio)**,
   **summary LLM (MLX Qwen3.5-4B-MLX-4bit)**, **embedding model (Apple NLContextualEmbedding)**
   — with real progress where the underlying provider can report it, honest "working, can't show
   progress" where it can't.
4. Marks itself done and never shows again (until a future explicit "reset onboarding" action, if
   ever added — no such action is in scope here).

**Seam:** this is a new UI + a thin new AriKit protocol seam, gated at app launch **after**
`AppEnvironment.status == .ready`, wrapping the existing 3-column shell (`RootSplitView.swift:41`)
the same way `LaunchStatusView` wraps the pre-ready states — see §6. It attaches to the existing
composition root (`AppEnvironment.bootstrap()`, `Ari/App/AppEnvironment.swift:154`), the existing
provider seams (`DiarizationProvider`, `AriKitEngineMLX.ModelHost`, `AppleContextualEmbedder`),
and the existing key-value settings store (`AriKit/Sources/AriKit/Store/Repositories/
SettingsRepository.swift`). No new migration phase, no new feature besides this one is opened.

---

## 2. Module & surface

### 2.1 New protocol in core `AriKit` (provider-agnostic, no 3rd-party imports)

Core `AriKit` must stay free of `FluidAudio`/`MLXHuggingFace` imports (the existing seam
discipline — see `FluidAudioDiarizationProvider.swift:12` "core `AriKit` never imports
FluidAudio"). So the unifying abstraction lives in `AriKit/Sources/AriKit/Engine/Onboarding/`,
mirroring the shape `DiarizationProvider` already established
(`AriKit/Sources/AriKit/Engine/Diarization/DiarizationProvider.swift:29-42`):

```swift
/// One on-device component this flow can report on / install. Sendable so it crosses actor
/// boundaries freely, mirroring `DiarizationProvider`.
public protocol OnboardingInstallableComponent: Sendable {
    var componentID: OnboardingComponentID { get }
    var displayName: String { get }

    /// Best-effort, filesystem-only hint for UI copy ("Already on this Mac" vs "~640 MB
    /// download") — NEVER authoritative and NEVER gates whether `ensureReady` is called.
    /// No-Fake-State: this is presented as a hint, not a guarantee, because none of the three
    /// backends expose a public "is this exactly the right cached model" check (see §2.2–2.4).
    func quickPresenceHint() async -> Bool

    /// Ensures the component is ready to use — downloads/compiles if needed, no-ops (fast) if
    /// already cached. Idempotent. Honest errors — never a fake-ready state. `progress` is called
    /// with real provider-reported progress when available; a provider that cannot report
    /// fractional progress calls it with `.indeterminate(phase:)` rather than being skipped
    /// silently, so the UI can still show *a* phase label without fabricating a percentage.
    func ensureReady(progress: (@Sendable (OnboardingInstallProgress) -> Void)?) async throws
}

public enum OnboardingComponentID: String, Sendable, CaseIterable {
    case diarization
    case summaryModel
    case embedding
}

public enum OnboardingInstallProgress: Sendable {
    case checking
    case downloading(fractionCompleted: Double)
    case compiling
    /// A provider is doing real work but cannot report a fraction (e.g. Apple's
    /// `NLContextualEmbedding.requestAssets()` — see §2.4). Never fabricate a fraction here.
    case indeterminate(phase: String)
}
```

`OnboardingComponentID` is deliberately **not** `SettingKey` or a DB-backed enum — it's a pure
UI/orchestration identifier, no persistence of its own (persistence is just the one "completed"
flag, §4).

### 2.2 Diarization conformance — extend, don't break, `DiarizationProvider`

`FluidAudioDiarizationProvider` (`AriKit/Sources/AriKitDiarizationFluidAudio/
FluidAudioDiarizationProvider.swift:35-37`) already has:

```swift
public func prepare() async throws {
    _ = try await preparedModels()
}
```

which calls `OfflineDiarizerModels.load(from:configuration:progressHandler:)`
(`FluidAudio/Diarizer/Offline/Core/OfflineDiarizerModels.swift:78-82`, verified against the pinned
FluidAudio 0.15.5 checkout at `spikes/fluidaudio-s3/.build/index-build/checkouts/FluidAudio/`).
That `load()` **already accepts a real `ProgressHandler`**
(`Shared/Download/DownloadTypes.swift:87`: `public typealias ProgressHandler = @Sendable
(DownloadProgress) -> Void`, with `DownloadProgress { fractionCompleted: Double; phase:
DownloadPhase }` where `DownloadPhase` is `.listing` / `.downloading(completedFiles:totalFiles:)`
/ `.compiling(modelName:)`) — `prepare()` today just doesn't forward it. This is a real,
concrete, low-risk change, not a guess:

- Add `func prepare(progress: (@Sendable (Double) -> Void)?) async throws` to the
  `DiarizationProvider` protocol as the sole requirement, and give the protocol a default-arg
  convenience via an extension:
  ```swift
  extension DiarizationProvider {
      public func prepare() async throws { try await prepare(progress: nil) }
  }
  ```
  This keeps `DiarizationService.swift:122`'s existing `try await provider.prepare()` call
  compiling unchanged — additive, not breaking (only one call site found via
  `rg "\.prepare\(\)"` across `AriKit/Sources`).
- `FluidAudioDiarizationProvider.preparedModels()` (lines 78-101) forwards its own
  `progress` parameter into `OfflineDiarizerModels.load(progressHandler:)`, translating
  `DownloadProgress` → the plain `Double` the protocol's `prepare(progress:)` promises (losing
  the phase detail at the `DiarizationProvider` boundary is fine — the richer
  `OnboardingInstallProgress` phase mapping happens one layer up, in the
  `AriKitDiarizationFluidAudio`-side `OnboardingInstallableComponent` conformer, which can call
  `OfflineDiarizerModels.load` directly with the full `DownloadProgress` rather than going through
  the narrower `DiarizationProvider.prepare` signature).
- **`quickPresenceHint()`:** FluidAudio does **not** expose a public "already downloaded" check
  for `OfflineDiarizerModels` — confirmed by reading `Shared/Download/ModelCache.swift:7,62,68`:
  `enum ModelCache` and its `allModelsExist`/`missingModels` are **internal to the FluidAudio
  module**, not `public`. So `quickPresenceHint()` for diarization is a best-effort
  `FileManager.fileExists` check on `OfflineDiarizerModels.defaultModelsDirectory()`
  `.appendingPathComponent(Repo.diarizer.folderName)` — exactly the path
  `FluidAudioDiarizationProvider.purgeDiarizerModelsCache()` already constructs
  (`FluidAudioDiarizationProvider.swift:111-113`) — non-empty directory ⇒ hint `true`. This is
  explicitly a hint, not a guarantee (a partial/corrupt download would hint `true` and then
  `ensureReady` would still do the real work and self-heal via the existing purge-and-retry-once
  path, lines 82-101).

### 2.3 Summary LLM (MLX) conformance

New small type in `AriKit/Sources/AriKitEngineMLX/` (not `MLXClient` itself — that's the
*inference* conformer; this is *installation*):

```swift
public struct MLXModelInstaller: OnboardingInstallableComponent {
    public let componentID: OnboardingComponentID = .summaryModel
    public let displayName = "On-device summary model"
    private let repoId: String
    private let host: ModelHost

    public init(repoId: String = AriKitEngineMLX.defaultModelID, host: ModelHost = .shared) { … }

    public func quickPresenceHint() async -> Bool { … }  // best-effort HF cache dir check, see below
    public func ensureReady(progress: ...) async throws {
        _ = try await host.container(forRepoId: repoId, progressHandler: /* adapt Foundation.Progress */)
    }
}
```

- `ModelHost.container(forRepoId:progressHandler:)` (`AriKit/Sources/AriKitEngineMLX/
  ModelHost.swift:46-49`) is single-flight and load-once per repo id — calling it during
  onboarding and later calling it again from `MLXClient.resolveContainer()`
  (`MLXClient.swift:179-187`) at first real summary generation is the **same cache**, so
  onboarding's download genuinely warms the path the app will use — no double-download, no wasted
  work.
- `progressHandler` there is typed `@Sendable @escaping (Progress) -> Void` (Foundation's
  `Progress`, confirmed via `swift-huggingface` 0.9.0's `downloadFile`/`downloadSnapshot`
  progress-reporting API: progress is exposed via a caller-supplied `Progress` object across
  `downloadFile`, `resumeDownloadFile`, `downloadSnapshot`). Adapt via `Progress.fractionCompleted`
  → `OnboardingInstallProgress.downloading(fractionCompleted:)`.
- **`quickPresenceHint()`:** `swift-huggingface` does **not** expose a documented "is this repo id
  already cached" check independent of attempting a download/snapshot fetch. Best-effort fallback:
  check for a non-empty directory under the HF hub cache root for the repo id (mirrors the
  diarization hint's honesty level — a hint, never authoritative). **Open verification item for
  the implementer:** confirm the exact on-disk cache layout `swift-huggingface`'s `HubCache` uses
  (its `location` API, `HubCache(location: .fixed(directory:))`) before hand-rolling a path guess
  — do not invent a path without reading `HubCache`'s actual default-location resolution in the
  vendored source once it's checked out locally.
- **Note the difference from FluidAudio:** MLX's real work (multi-GB download) happens on first
  use if onboarding is skipped/dismissed — unlike diarization, nothing else in the app currently
  pre-warms this cache. So onboarding is the *only* place a user gets to see this large download
  with an explanation, unless they trigger it by generating their first summary cold. That's fine
  (dismissible flows are explicitly allowed, §5) but worth calling out: skipping onboarding just
  defers the same download to the first summary, it doesn't avoid it.

### 2.4 Embedding conformance — correcting a task-brief assumption

The initial assumption was that the embedding model needs "no download… just maybe a ready
check." Reading `AriKit/Sources/AriKit/Recall/Embedding/AppleContextualEmbedder.swift:71-97` shows
this is **not quite right**: `NLContextualEmbedding` (unlike the retired `NLEmbedding`) **does**
have its own first-run asset story —

```swift
if !model.hasAvailableAssets {
    let result = try await model.requestAssets()   // an OTA asset fetch, no progress fraction exposed
    guard result == .available else { throw … }
}
try model.load()
```

So the embedding conformer is real, not a no-op:

```swift
extension AppleContextualEmbedder: OnboardingInstallableComponent {
    public var componentID: OnboardingComponentID { .embedding }
    public var displayName: String { "Meeting search embedding model" }
    public func quickPresenceHint() async -> Bool {
        NLContextualEmbedding(language: .english)?.hasAvailableAssets ?? false
    }
    public func ensureReady(progress: ...) async throws {
        progress?(.indeterminate(phase: "Checking on-device language model…"))
        _ = try await loadedModelInstance()   // reuses the actor's existing lazy-load path
    }
}
```

`NLContextualEmbedding.requestAssets() -> AssetsResult` (Apple's `NaturalLanguage` framework) has
**no progress-fraction API** in its public surface (it's a coarse "requesting → available/
unavailable" outcome) — hence `.indeterminate`, never a fabricated percentage (No-Fake-State).
This requires exposing `loadedModelInstance()` (currently `private`,
`AppleContextualEmbedder.swift:74`) as `internal`/a new visible entry point, or adding the
conformance's `ensureReady` as a thin wrapper that calls the existing `public func embed(_:)` with
a throwaway string to force the lazy load — the cleaner option is making `loadedModelInstance()`
`package`/internal-visible and calling it directly; avoid the throwaway-string hack (it would
silently rely on English-language embedding succeeding on empty-ish input, which is exactly the
kind of implicit behavior No-Fake-State discourages when a direct entry point is cheap to add).

### 2.5 Hardware capability check (fully net-new — no existing Swift code)

New pure, testable type in `AriKit/Sources/AriKit/Engine/Onboarding/HardwareCapability.swift`:

```swift
public struct HardwareCapability: Sendable, Equatable {
    public let physicalMemoryGB: Double        // ProcessInfo.processInfo.physicalMemory / 1e9
    public let processorCount: Int             // ProcessInfo.processInfo.processorCount
    public let isAppleSilicon: Bool            // always true on this platform floor — see below

    public static func current() -> HardwareCapability { … }
}

public enum SummaryModelComfort: Sendable, Equatable {
    case comfortable
    case belowComfortThreshold(recommendedGB: Double)
}

public enum HardwareAssessment {
    /// Pure function (testable without touching real hardware): informational only, per the
    /// product owner's explicit direction — NEVER used to block continuing.
    public static func assessSummaryModelComfort(
        _ capability: HardwareCapability,
        thresholdGB: Double = /* see open decision below */
    ) -> SummaryModelComfort { … }
}
```

- `ProcessInfo.processInfo.physicalMemory` (`UInt64`, bytes) is a real, documented Foundation API
  — this is the same signal the old Rust flow used (`get_system_ram_gb()`,
  `frontend/src/lib/model-tiers.ts:96-104` thresholds 12/20 GB), just re-grounded for one model
  tier instead of three.
- **Deliberately no "chip name" (M1/M2/M3…) lookup.** There is no stable public API mapping
  `sysctlbyname("hw.model")` output (e.g. `"Mac16,3"`) to a marketing chip name without a
  hand-maintained table that goes stale every hardware refresh — that's exactly the kind of
  fragile invented-precision the brand's honesty register (`brand/BRAND.md` §2, "Numbers are
  exact or absent — never rounded theatrics") warns against. RAM + core count is honest and
  sufficient; report those, not a guessed chip name.
- `isAppleSilicon` is trivially `true` given the platform floor (`.claude/rules/
  platform-and-deps.md` — Apple Silicon only) — kept as a field mostly so the type is
  self-documenting and the assessment logic doesn't silently assume it.
- **Open decision, flagged not resolved:** the RAM comfort threshold for the MLX Qwen3.5-4B-4bit
  summary model. The old Rust tiers used 12 GB / 20 GB thresholds for a *different* model set
  (Parakeet+Qwen-2B vs Whisper+Qwen-4B) and are not directly transferable. No Swift-side memory
  benchmark for the MLX build exists yet. **This plan does not invent a threshold number.**
  Recommend a cheap pre-implementation spike: run one real summary generation under
  Instruments/Activity Monitor on a real 16 GB and a real 8 GB Apple Silicon Mac (if available) to
  get one honest data point, then pick the threshold from that, documenting the measurement in
  the implementation PR. Until then, ship the comfort check with the RAM number displayed but the
  soft-warning UI copy held back (see §5) rather than fabricate a threshold.

---

## 3. Concurrency model

- All three `ensureReady` calls happen **off the main actor**, in an async `Task` owned by an
  `@Observable` view model (see §5) — never the main actor directly, since `MLXModelInstaller`'s
  underlying `ModelHost.container` is a multi-second-to-multi-minute network+compile operation and
  `FluidAudioDiarizationProvider`'s `preparedModels()` compiles CoreML models synchronously inside
  its `await`.
- `OnboardingInstallableComponent` is `Sendable`; `ensureReady`'s `progress` closure is `@Sendable`
  — the same shape `DiarizationProvider.diarize(progress:)` already uses
  (`DiarizationProvider.swift:40`), so this isn't a new concurrency pattern, just a reuse of an
  established one.
- The three installs can run **concurrently** (`async let` / `TaskGroup`) since they touch
  independent caches (FluidAudio's CoreML repo dir, the HF hub cache for MLX, `NaturalLanguage`'s
  private asset store) — no shared mutable state between them. The view model fans out progress
  from each into per-component `@Observable` state, not a single merged fraction (never
  fabricate a "combined progress" number that doesn't correspond to real combined work — three
  differently-sized, differently-phased downloads don't sum into one honest percentage).
- Cancellation: if the user quits the app mid-download, `Task` cancellation propagates into
  `ModelHost`'s underlying `loadModelContainer` call and FluidAudio's `ModelHub.loadModels` (which
  explicitly treats cancellation as "preserve cache, don't purge" — confirmed in the FluidAudio
  source) — so a killed app never corrupts a partial download into looking like a corrupt one that
  gets purged. No new handling needed here; just don't add a cancel-triggered cleanup path that
  fights this existing safety behavior.
- No `@unchecked Sendable` anywhere in this design — `OnboardingInstallableComponent` conformers
  are either actors (`AppleContextualEmbedder`, `FluidAudioDiarizationProvider`) or plain
  `Sendable` structs holding only `Sendable` state (`MLXModelInstaller`).

---

## 4. Persistence

**No new migration.** The only durable state this flow needs is a single "onboarding completed"
boolean, and the store already has a generic key-value settings table for exactly this shape
(`AriKit/Sources/AriKit/Store/SettingKey.swift`, `Repositories/SettingsRepository.swift` —
`setBool(_:forKey:)`/`bool(forKey:)` already exist, backed by `SettingRecord` rows in the existing
`setting` table from `v1_baseline`).

- Add one new case to the existing `SettingKey` enum (a Swift source change, not a DDL change —
  the table itself is untyped key/value, so no `ALTER TABLE` is needed):
  ```swift
  /// Whether the first-run model-install/education flow has been completed or explicitly
  /// dismissed (docs/plans/onboarding-install-flow.md). Absent (nil) means "never shown" —
  /// distinguished from `false`, which this flow never actually writes (it writes `true` only on
  /// completion/dismissal, mirroring SettingsRepository's honest-absence pattern: an
  /// unknown/absent key returns nil, this repository never fabricates a default).
  case onboardingCompleted
  ```
- This satisfies the migration-safety rule (`.claude/rules/swift-conventions.md` "Migration
  safety" §, `v1_baseline` frozen) trivially — it's additive at the *data* level (a new row with a
  new key), not the *schema* level, so there is nothing to migrate at all.
- **Single-DB-owner rule preserved**: this flag is read/written through `SettingsRepository` like
  every other setting — no new table, no second writer, no raw SQLite handle in the onboarding
  view model.
- If the implementer wants a persisted "which components were seen as needing install" history
  for debugging/support purposes, **don't add it** unless there's a real need — that's the kind of
  speculative schema surface the migration-safety incident (`docs/plans/
  robust-migration-and-backup.md`) explicitly warns against adding casually to a frozen baseline
  world. The three providers' own `quickPresenceHint()`/`ensureReady()` are already the source of
  truth; don't shadow them in the DB.

---

## 5. SwiftUI flow — screens

Deliberately **not** a multi-step wizard (per the product owner's "really easy… not lots of
options" direction) — one screen with two honest states, shown as a full-screen cover over
`RootSplitView`'s ready shell (see §6 for exactly where):

**Screen: "Setting up Ari"** (working title — final copy is an implementation detail, but must
follow `brand/BRAND.md` §2 voice rules: sentence case, active voice, no exclamation marks, no
invented percentages).

1. **Header block** (always shown): the `DictationMark` brand mark (same as `LaunchStatusView`,
   `Ari/UI/AppShell/LaunchStatusView.swift:17-22`) + one short paragraph of "why local" education,
   reusing the register already established in `brand/BRAND.md` §1 "What stays local" — do not
   author new privacy claims, restate the existing ones ("everything stays on this Mac; nothing
   leaves unless you configure a cloud provider yourself").
2. **Hardware readout row** (always shown, informational): "This Mac has N GB of memory." If
   `HardwareAssessment.assessSummaryModelComfort` returns `.belowComfortThreshold`, an *additional*
   single sentence in muted ink (never `recordingRed` — that's reserved for capture, per
   `BRAND.md` §3.4/§4): "Summaries may run slowly on this hardware — the app will still work."
   Never a hard stop, never a disabled Continue button — the product owner was explicit this is
   soft.
3. **Per-component rows** (one row each for diarization / summary model / embedding), each
   showing:
   - Display name + one-line plain-language purpose ("Tells speakers apart in a recording",
     "Writes your meeting summaries", "Powers 'Ask my meetings' search").
   - State: `quickPresenceHint()`-informed initial label ("Already on this Mac" / "~640 MB to
     download" — sizes are the FluidAudio/HF repo's own reported sizes if obtainable at listing
     time, not hand-maintained constants that go stale like the old `model-tiers.ts` numbers did;
     if a real size can't be read at this point, omit the size rather than guess), then live state
     during `ensureReady`: `.checking` → `.downloading(fraction)` (a real `ProgressView(value:)`)
     → `.compiling` (a real indeterminate `ProgressView()`) → `.indeterminate(phase:)` (spinner +
     phase label, no fabricated fraction) → done (checkmark) or an honest per-row error with a
     Retry button (never a silent failure — mirrors `AppEnvironment.Status.failed` honesty).
4. **Primary action:** "Continue" — starts (or, if already running, just waits on) all three
   `ensureReady` calls concurrently, then writes `onboardingCompleted = true` and dismisses. A
   **secondary "Skip for now"** action is worth considering (matches "the flow can be dismissed,
   the download just happens later at first use" reality from §2.3) — flag this as an **open UX
   decision for the human**, not resolved here: does "skip" still mark `onboardingCompleted =
   true` (never show again) or leave it `nil` (show again next launch until actually completed)?
   Recommend the former (never re-nag) but this is a product call, not an architecture call.

No wizard chrome (no page dots, no back/next between steps) — everything is visible on one
screen, consistent with "the swift version is really easy."

---

## 6. Where this gates in the app

`RootSplitView.swift:39-46` currently does:
```swift
if let database = environment.database, environment.status == .ready {
    readyShell(database: database)
} else {
    LaunchStatusView(status: environment.status)
}
```

Proposed: once `.ready`, check the persisted flag (via a new `@Observable` `OnboardingViewModel`
constructed in `AppEnvironment.bootstrap()` alongside `summaryRunner`/`diarizationService` etc. —
same pattern as every other `bootstrap()`-gated service at `Ari/App/AppEnvironment.swift:80-104`)
and present the flow as a covering layer over `readyShell`, not instead of it — the meeting
list/etc. should still be visually present underneath (or at least constructible), matching "this
doesn't block the app being otherwise usable" if the user dismisses early.

This is a **new, small, additive branch** in `RootSplitView` — not a rework of the existing
`.launching`/`.importing`/`.failed` states, which stay exactly as they are.

---

## 7. Acceptance tests (write first, Swift Testing)

**Pure logic (no model downloads, run in every CI run):**

1. `HardwareAssessmentTests` — `assessSummaryModelComfort` returns `.comfortable` above the
   threshold, `.belowComfortThreshold(recommendedGB:)` below it, boundary-inclusive behavior
   pinned once the threshold is chosen (§2.5's open decision).
2. `OnboardingComponentIDTests` — `CaseIterable` covers exactly the three documented components
   (a change-detector test: adding a 4th component without updating the UI row list should fail
   loudly, not silently).
3. `SettingsRepositoryOnboardingTests` (extends the existing `SettingsRepository` test suite,
   doesn't create a new pattern) — `bool(forKey: .onboardingCompleted)` returns `nil` before any
   write (never a fabricated `false`), `true` after `setBool(true, forKey: .onboardingCompleted)`.
4. `DiarizationProviderPrepareProgressTests` — a fake `DiarizationProvider` conformer confirms the
   new `prepare(progress:)` requirement's default-arg extension (`prepare()` → `prepare(progress:
   nil)`) compiles and behaves identically to the old zero-arg call, i.e. the existing
   `DiarizationService.swift:122` call site's behavior is provably unchanged (a regression guard
   for the signature widening in §2.2).
5. `OnboardingInstallProgressTests` — the FluidAudio `DownloadProgress`→`Double` translation used
   by `FluidAudioDiarizationProvider.prepare(progress:)` and the MLX `Foundation.Progress`→
   `OnboardingInstallProgress` adapter each map known fixture inputs to the expected cases
   (pure, no network).

**Integration-shaped (may be `.disabled` in CI if they'd trigger a real multi-hundred-MB
download — gate behind an explicit opt-in env var the way FluidAudio's own `offlineMode` does,
rather than silently skip or silently run in every CI pass):**

6. `MLXModelInstallerTests` — `ensureReady` against a real (small/cached) repo id resolves without
   error and reuses `ModelHost`'s existing single-flight cache (assert no duplicate `Task` per
   concurrent call — mirrors `ModelHost`'s own existing single-flight tests, extend rather than
   duplicate).
7. `AppleContextualEmbedderInstallableTests` — `ensureReady` resolves after `requestAssets()`
   succeeds on a real device with the assets available; a device/language without assets
   surfaces the existing `RecallEmbedderError.modelUnavailable` honestly, never a fake-ready state.
8. `FluidAudioOnboardingPresenceHintTests` — `quickPresenceHint()` returns `false` against an
   empty temp directory and `true` against a directory pre-seeded with the expected repo
   folder-name structure (a filesystem fixture, no real download) — pins the honesty boundary of
   the hint (never claims more than "a directory with this name exists").

**UI/view-model (Swift Testing where feasible, XCUITest/XcodeBuildMCP screenshot pass for the
human gate mentioned below):**

9. `OnboardingViewModelTests` — fan-out/fan-in of three fake `OnboardingInstallableComponent`
   conformers (one slow-with-progress, one fast-cached, one erroring) produces the expected
   per-row state transitions and an overall "all done" signal only when all three genuinely
   succeed (never optimistic-completes on a still-in-flight or errored component).
10. A human visual pass (screenshot via XcodeBuildMCP) confirming: no page-dots/wizard chrome, no
    fabricated percentage anywhere, the soft-warning copy renders only when hardware is genuinely
    below threshold, Marginalia tokens (not ad-hoc colors) are used throughout.

**Invariant carry-forward:** No dedicated "dual-run against the Rust incumbent" suite applies here
— per §0, this isn't a 1:1 port of the old onboarding wizard, so there's no old behavior to match
bit-for-bit. The relevant invariant to preserve is **No-Fake-State** (tests 1–10's repeated "never
fabricate a percentage/threshold/default" assertions ARE the invariant tests for this feature) —
there is no S1–S4 spike gate applicable (no model-quality question is being decided here, only
UI/orchestration).

---

## 8. Invariants preserved

- **No-Fake-State** — the load-bearing invariant for this whole feature. Every progress signal
  traces to a real provider callback (FluidAudio's `DownloadProgress`, MLX's `Foundation.Progress`)
  or an honest `.indeterminate` state; the hardware comfort threshold is informational, never a
  block; `quickPresenceHint()` is documented and tested as a *hint*, never authoritative;
  `SettingsRepository`'s existing "absent key ≠ fabricated default" contract is reused, not
  reinvented.
- **Consent-before-record** — not touched by this plan (this flow does not request
  mic/screen/calendar permissions; that remains explicitly out of scope, see §0). No regression
  risk since nothing here calls into `AVCaptureDevice`/`EventKit` authorization.
- **Recall safety shell** — not touched; the embedding conformer only wraps existing
  `AppleContextualEmbedder` asset-loading, never its `embed(_:)` retrieval path.
- **Single-DB-owner** — preserved (§4): one new `SettingKey` case, same repository, same
  `AppDatabase`, no second writer.

---

## 9. Risks & sequencing

1. **Verify `swift-huggingface`'s actual cache-presence/progress API against the real vendored
   source** before writing `MLXModelInstaller` — a doc summary is not a substitute for reading the
   checked-out source (`AriKit/Package.resolved` pins the exact revision).
2. **Calibrate the RAM comfort threshold (§2.5)** before shipping the soft-warning copy — this is
   an explicit open decision, not resolved by this plan. Recommend one real measurement pass
   before picking a number.
3. **Decide the "Skip" semantics (§5.4)** — re-nag every launch vs. never re-nag. Product call,
   flagged not resolved.
4. **`DiarizationProvider.prepare(progress:)` signature widening (§2.2)** is the one change that
   touches code outside this new module — small, additive, one call site, tested (acceptance test
   4), but it should land and be reviewed as its own small commit before the rest of this feature,
   so a regression there is easy to isolate.
5. **Sequencing within this one feature** (each step independently testable, per the WIP-limit
   discipline):
   1. `OnboardingInstallableComponent`/`OnboardingComponentID`/`OnboardingInstallProgress` +
      `HardwareCapability`/`HardwareAssessment` (pure, testable, no UI, no provider changes).
   2. `DiarizationProvider.prepare(progress:)` widening + `FluidAudioDiarizationProvider`
      conformance to `OnboardingInstallableComponent` (test 4, 8).
   3. `MLXModelInstaller` (test 6) — gated on risk #1 above being resolved first.
   4. `AppleContextualEmbedder` conformance (test 7) — smallest of the three, no download, just
      the asset-request wrapper.
   5. `OnboardingViewModel` (test 9) composing all three.
   6. SwiftUI screen + `RootSplitView` gating (§6) + human visual pass (test 10).
6. **Nothing here needs a Rust sidecar fallback** — every component (FluidAudio, MLX, Apple
   NaturalLanguage) is already the live Swift-native implementation; there is no spike gate to
   miss and no "keep it behind the engine protocol" fallback applicable.

---

## Decisions (resolved 2026-07-23)

1. **RAM comfort threshold: 16 GB.** `HardwareAssessment.assessSummaryModelComfort` uses
   `thresholdGB: Double = 16.0` as the default. Below 16 GB physical memory, show the soft
   "may run slowly" copy (§5.2) — never a block.
2. **"Skip" semantics: never re-nag.** Tapping "Skip for now" writes
   `onboardingCompleted = true` immediately, same as completing the flow normally. Downloads not
   yet triggered simply happen lazily on first real use of each feature (diarization on first
   recording, summary model on first summary, embedding on first Ask/recall query) — consistent
   with §2.3's existing "MLX download happens on first use if skipped" behavior.
3. **Presentation primitive** on macOS 26 for the covering flow over `RootSplitView` (§6) —
   full-screen cover vs. a separate modal `Window` — implementer's call once in Xcode, not an
   architecture decision.
4. **SpeechAnalyzer/`AssetInventory` on-demand asset installation** (§0) — explicitly out of scope
   here per the user's direction, but flagged as a real gap: if STT assets are ever *not*
   pre-installed on a fresh macOS 26 install, first-run transcription could stall silently with no
   onboarding coverage. Worth a separate, later decision on whether it deserves its own small
   follow-up plan.
