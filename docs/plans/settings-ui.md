# Plan: Native Swift Settings screen

Status: PLAN (2026-07-21). Executed by an implementation workflow (swift-implementer × foundation + 5 sections + integration, swift-code-reviewer gate).

## 1. Goal & seam

Build the **full native Settings UI shell** for the macOS `Ari` app, reaching functional-shell parity with the frozen Rust/React 5-tab settings, plus a **real native persistence layer** for the controls wireable from Swift today and **honest No-Fake-State disabled states** for the ones whose backend still lives in the frozen Rust engine.

**Seam / phase:** Phase 2 native shell (UNDERWAY). Attaches on the Swift side of two cut seams — the GRDB store (`AriKit/Sources/AriKit/Store/AppDatabase.swift`) and the SwiftUI shell (`Ari/UI/AppShell/RootSplitView.swift`).

**Net-new, not a re-implementation:** there is zero settings persistence in the Swift tree today — no settings table, no Keychain, no `@AppStorage`, only stub-only `SettingsReading`/`SecretsReading` protocols (`AriKit/Sources/AriKit/Engine/Summary/SummarySettings.swift`, `StubSettings.swift`). We build the concrete backing the protocol headers defer to "the app target's job, later."

**Surface (decided):** a new `SidebarSection.settings` case, rendered full-window in the detail column (NOT a sheet). Section switcher lives in the toolbar via `ToolbarItem(placement: .principal)` + stock segmented `Picker` — glass comes from the toolbar layer. `MarginaliaSegmentedControl`/`MarginaliaGlassTabs` are BANNED.

**Scope (decided):** FULL UI shell for ALL sections now + honest disabled/"available once the engine ports" states for Rust-only backends. Real native persistence for what IS wireable.

**EXCLUDE entirely:** the "Apple Intelligence" summary/embedding panels — `AppleModelStatus`, summary `apple-foundation` branch, apple embedder. Do not port or placeholder them.

> **AMENDED 2026-07-21 — Transcription is now a LIVE Apple panel.** The original plan excluded the transcription `apple` branch and shipped the Transcription tab honest-disabled around a Parakeet/Whisper picker. That was based on the (now stale) premise that Swift transcription still ran in the frozen Rust engine. It does not: the Swift app records and transcribes **on-device with Apple `SpeechTranscriber`** (AriKit `Engine/STT/`, shipped), so the disabled Parakeet/Whisper panel actively misrepresented the app. The Transcription tab is now LIVE over `SpeechAssetManager` (engine availability + on-device model download). Apple SpeechTranscriber is the Swift app's **sole** transcription engine — there is no provider/model/language choice (transcription follows the system language). See §6.

## 2. Persistence design

### 2.1 New key-value `setting` table + `SettingsRepository`

Extend the still-unshipped `v1_baseline` migration in place (`SchemaMigrator.swift`), appended after `askMessage`:

```
setting(
  key       TEXT     PRIMARY KEY,
  value     TEXT     NOT NULL,
  updatedAt DATETIME NOT NULL
)
```

Key-value (not the Rust wide single-row shape): additive keys need no future migration; per-key rows give per-key CloudKit conflict resolution at Phase 5.5; maps cleanly to typed accessors. No tombstone columns (config, not synced content — mirrors `calendarSyncSetting`).

New files (AriKit Store, matching `MeetingRecord`/`MeetingRepository` conventions):
- `AriKit/Sources/AriKit/Store/Records/SettingRecord.swift` — `struct SettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable { static let databaseTableName = "setting"; var key: String; var value: String; var updatedAt: Date }`
- `AriKit/Sources/AriKit/Store/Repositories/SettingsRepository.swift` — `public struct SettingsRepository: Sendable { let dbWriter: any DatabaseWriter }` with:
  - `func string(forKey: SettingKey) async throws -> String?`
  - `func bool(forKey:) async throws -> Bool?` / `int(forKey:)` (parse stored string; unknown/absent → `nil`, never a fabricated default — the *caller* applies the documented default)
  - `func setString(_:forKey:)` / `setBool` / `setInt` (upsert, stamp `updatedAt = now`)
  - `func remove(forKey:)`
  - `func all() async throws -> [String: String]`
  - `func observeString(forKey:) -> AsyncStream<String?>` (GRDB `ValueObservation`, mirroring `MeetingRepository.observeAll()`)
- `AppDatabase.swift` accessor (after `askConversations`): `public nonisolated var settings: SettingsRepository { SettingsRepository(dbWriter: dbWriter) }`
- `AriKit/Sources/AriKit/Store/SettingKey.swift` — `public enum SettingKey: String, Sendable, CaseIterable`:
  - `summaryProvider`, `summaryModel`, `summaryOllamaEndpoint`, `summaryCustomOpenAIConfig` (JSON), `summaryLanguage`, `summaryAutomatic`
  - `recallEmbedder`
  - `generalShowNotch`, `generalShowInMenuBar`, `generalRecordingAlerts`
  - `recordingsSaveAudio`, `recordingsStartNotification`, `recordingsMicDevice`, `recordingsSystemDevice`, `recordingsAudioBackend`
  - `transcriptionProvider`, `transcriptionModel`
  - (theme is deliberately NOT here — see 2.4)

Single-DB-owner reasserted: `SettingsRepository` reaches the file only through the injected `dbWriter`; no feature code opens SQLite directly.

### 2.2 Secrets: Keychain, never the DB

API keys go to the macOS Keychain, never SQLite, never CloudKit (improving on the Rust plaintext columns).
- `Ari/App/Settings/KeychainSecretStore.swift` — `Sendable` struct wrapping `Security` `SecItemAdd/Copy/Update/Delete` (service = `com.arivo.ari`, account = provider key). Stateless value; no `@unchecked Sendable` needed. Conforms to `AriKit.SecretsReading`, `AriKit.RecallSecretsReading`, and the new `SecretsStoring` (2.3).

### 2.3 App-target concrete conformers (the deferred "app's job")

- `Ari/App/Settings/StoreBackedSettingsReading.swift` — `struct StoreBackedSettingsReading: SettingsReading, Sendable` over `AppDatabase.settings`: `ollamaEndpoint()` ← `summaryOllamaEndpoint`; `customOpenAIConfig()` ← JSON-decode `summaryCustomOpenAIConfig`; `summaryModelConfig()` ← `summaryProvider`+`summaryModel`; `ollamaContextSize`/`mlxContextSize` → `nil` (honest; `SummaryService` applies its 4000/1748 fallbacks). Never throws for "unset".
- `Ari/App/Settings/StoreBackedRecallSettingsReading.swift` — `struct … : RecallSettingsReading`: `modelConfig()` ← `summaryProvider`/`summaryModel`/`summaryOllamaEndpoint`.
- `AriKit/Sources/AriViewModels/Support/SecretsStoring.swift` — `public protocol SecretsStoring: Sendable { func apiKey(for: String) async -> String?; func setAPIKey(_:for:) async throws; func deleteAPIKey(for:) async throws }` + a `#if DEBUG` in-memory `StubSecretsStoring` for headless VM tests.
- `AppEnvironment` gains `let secrets: SecretsStoring` (a `KeychainSecretStore`), constructed in `bootstrap()`, exposed to the view tree.

### 2.4 The one `@AppStorage` exception: theme (DECIDED)

Appearance/theme is stored as `@AppStorage("appAppearance")` read at the SwiftUI app root — NOT in the `setting` table. Justification: theme must apply to the first frame (including `LaunchStatusView`, before the DB opens), is intrinsically device-local, and is never a sync candidate. The VM exposes theme via an injected `AppearanceStore` accessor for a uniform section surface, but the durable store is `UserDefaults`.

### 2.5 Migration + tests to update
- Extend `v1_baseline` in `SchemaMigrator.swift` (in place).
- `SchemaFidelityTests.noExtraTablesYet` — add `"setting"` to the expected set. Add `settingSchema()` asserting the three columns + PK + no tombstones, using the existing `assertColumns` helper.

## 3. Concurrency model

- `SettingRecord`/`SettingsRepository` are `Sendable` value types over the `Sendable` `dbWriter`; all I/O hops off the main actor via `dbWriter.read/write`. Off-main by construction.
- `SettingsViewModel` / `CalendarSettingsViewModel`: `@MainActor @Observable final class` in `AriViewModels`; `await` suspending repo calls; observation streams consumed in a VM-owned `Task` with an idempotency guard (mirror `HomeViewModel`).
- `KeychainSecretStore`: `Sendable`; `SecItem*` synchronous + thread-safe; not on any hot path — settings I/O is user-driven config, off the audio/STT loops entirely.
- No `@unchecked Sendable` / `nonisolated(unsafe)`. Swift 6 strict-concurrency clean.

## 4. Module & surface

- **AriKit (Store):** `SettingRecord`, `SettingsRepository`, `SettingKey`, `AppDatabase.settings`.
- **AriViewModels:** `SecretsStoring` (+ stub), `SettingsViewModel`, `CalendarSettingsViewModel`.
- **App target (`Ari/`):** Keychain + Store-backed conformers, `AppEnvironment.secrets`, all SwiftUI section views + routing.

## 5. ViewModel design

**`SettingsViewModel`** (`AriKit/Sources/AriViewModels/SettingsViewModel.swift`), `@MainActor @Observable`, `init(database: AppDatabase, secrets: SecretsStoring, appearance: AppearanceStore)`:
- Observable published prefs (one per `SettingKey`), each with an honest **default constant** applied only when the store returns `nil` (never a fabricated value).
- Per-control availability: an `Availability` value (`.live` / `.disabled(reason: String)`) exposed per control group so the view renders the honest-disabled banner from real state, not hardcoded copy. Encodes the No-Fake-State bar (testable).
- API-key surface: `hasAPIKey(for:) -> Bool` presence only — never expose key text; `setAPIKey`/`deleteAPIKey` proxy to `secrets`.
- Recall index stats: `indexSummary` (real `RecallIndexRepository.indexSummary()`) or honest empty; "Rebuild index" action is `.disabled` (no Swift reindex command yet).
- `load() async` (one-shot, honest per-property handling) + optional live `observe()`.
- **Delivered whole in the FOUNDATION slice** so the 5 section slices only compose views and never edit the VM (parallel-safe).

**`CalendarSettingsViewModel`** (`AriKit/Sources/AriViewModels/CalendarSettingsViewModel.swift`): honest `permission` state (`.notDetermined` today — no EventKit) + `calendars` from `CalendarEventRepository.syncSettings()`, `setSelected(_:for:)` → `setSyncSetting(...)`. No EventKit source yet ⇒ honestly empty list, "Grant access" disabled with reason.

## 6. View structure — files and per-control classification

Shell `Ari/UI/Settings/SettingsView.swift`: `MarginaliaCanvasWash(scheme:)` ground, `.scrollEdgeEffectStyle(.soft, for: .top)`, toolbar section switcher:
```
.toolbar { ToolbarItem(placement: .principal) {
    Picker("", selection: $tab) { ForEach(SettingsTab.allCases) … }.pickerStyle(.segmented)
} }
```
No in-content segmented control. `switch tab { … }` renders one section. Owns `SettingsViewModel` + `CalendarSettingsViewModel` (constructed in `init`, `.task { await vm.load() }`).

Foundation support files:
- `Ari/UI/Settings/SettingsTab.swift` — `enum SettingsTab: CaseIterable { case general, recordings, transcription, summary, calendar }` (+ sentence-case titles; stock Picker labels, not uppercased).
- `Ari/UI/Settings/SettingsCard.swift` — opaque canonical card recipe (`RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style:.continuous).fill(.elevated).overlay(strokeBorder(.hairline,1))`). Content layer stays paper, never glass.
- `Ari/UI/Settings/SettingsDisabledGroup.swift` — wraps a group in `.disabled(true)` + `MarginaliaBanner(kind: .info, message:, scheme:)` rendering the VM's `reason`. The honest-disabled treatment used by all sections.

Each section mirrors `PersonDetailView` (ScrollView → `VStack(alignment:.leading, spacing:.md)` → `SectionHeader` + rows). Apple panels excluded entirely.

### `SettingsGeneralSection.swift`
| Control | Primitive | Classification |
|---|---|---|
| Appearance (System/Light/Dark) | stock `Picker(.segmented)` bound to `@AppStorage`/`AppearanceStore` | **LIVE** (native theme) |
| Show meeting notch | `MarginaliaToggleRow` | **HONEST-DISABLED** — notch is a Rust sidecar |
| Show in menu bar | `MarginaliaToggleRow` | **HONEST-DISABLED** — no menu-bar item yet |
| Recording alerts / notifications | `MarginaliaToggleRow` | **HONEST-DISABLED** — notifications not built Swift-side |
| Recordings path (read-only) + Open Folder | `Text` + `.marginalia(.secondary)` button → `NSWorkspace.open` | **LIVE** — real path from `AppEnvironment` |

### `SettingsRecordingsSection.swift`
| Control | Primitive | Classification |
|---|---|---|
| Save audio recordings | `MarginaliaToggleRow` | **LIVE** persist |
| Save location (read-only) + Open Folder | text + secondary button | **LIVE** |
| File format (informational) | `Text` caption | **LIVE** (informational) |
| Recording start notification | `MarginaliaToggleRow` | **HONEST-DISABLED** |
| Default mic / system device dropdowns + Refresh | `MarginaliaMenuLabel` in stock `Picker(.menu)` | **HONEST-DISABLED** — device enumeration is capture S2–S5, not built |
| Audio backend selector | radio rows | **HONEST-DISABLED** |

### `SettingsTranscriptionSection.swift`
**LIVE** over `SpeechAssetManager` (AMENDED 2026-07-21 — see §1). The Swift app transcribes on-device with **Apple Speech**; there is no provider/model/language choice (transcription follows the Mac's system language). Rendered as **ONE card** with a single collapsed readiness state (the earlier two-badge "Available" + "Installed" pairing read as redundant on the happy path). The `transcriptionLanguage` key is retained as the seam the recording path reads (defaults to the `"auto"` sentinel = system language); a future language control would write it. User-facing name is "Apple Speech" everywhere (incl. the meeting provenance line, mapped from the stored `speech-transcriber`/`speechanalyzer` ids in `SourceRecordPanel`).
| State | Rendering | Classification |
|---|---|---|
| Engine available + model installed | one card + **"Ready"** badge | **LIVE** — `isEngineAvailable()` && `areAssetsInstalled()` |
| Engine available + model missing | Download button + real progress / `MarginaliaBanner(.error)` on failure | **LIVE** — `install(forLocale:onProgress:)` |
| Engine unavailable | "Unavailable" badge + `MarginaliaBanner(.error)` | **LIVE** — `isEngineAvailable()` |

### `SettingsSummarySection.swift` (largest)
| Control | Primitive | Classification |
|---|---|---|
| Automatic summary | `MarginaliaToggleRow` | **LIVE** persist |
| Summary language (MRU chips + default pin) | `MarginaliaBadge`/chips + flow layout | **LIVE** persist |
| Summary model config — provider picker (builtin-ai / ollama / claude-cli visible; cloud hidden; apple-foundation excluded) | `MarginaliaMenuLabel` in `Picker(.menu)` | **LIVE persist** — writes `summaryProvider`/`summaryModel` |
| Ollama endpoint field | `MarginaliaTextField` | **LIVE persist** (`summaryOllamaEndpoint`) — recall loopback policy still enforced in engine |
| API key entry (lock/show-hide) | secure `MarginaliaTextField` + button | **LIVE** via Keychain — presence only, never the stored key |
| Endpoint validation | inline `MarginaliaBanner` on validate | **LIVE** (client-side format check) |
| Per-provider model download managers | `SettingsCard`, disabled | **HONEST-DISABLED** |
| Meeting search index — Rebuild button | button, disabled | **HONEST-DISABLED** |
| Embedder cards (apple excluded → nomic-gguf / ollama; **default = ollama**) | radio rows | selection persists (`recallEmbedder`) **LIVE**; Nomic download **HONEST-DISABLED** |
| Index stats (read-only) | `Text` from `RecallIndexSummary` | **LIVE** (real counts) or honest empty |

### `SettingsCalendarSection.swift`
| Control | Primitive | Classification |
|---|---|---|
| Permission gate (Grant access) | `MarginaliaButtonStyle(.primary)` disabled + banner | **HONEST-DISABLED** — EventKit/TCC not built Swift-side |
| Per-calendar sync toggles (color dot + name) | `MarginaliaToggleRow` + color swatch | store round-trip **LIVE**; list honestly empty until EventKit populates |

## 7. Routing wiring
- `SidebarSection.swift` — add `case settings`; add `title`/`symbolName` (exhaustive switches). Do NOT add to `workbench` — it stays a pinned bottom-rail destination.
- `SidebarView.swift:261-269` — replace the disabled pinned "Settings" stub with a real `Button { selection = .settings }` reflecting selection highlight (mirror `workbenchRow`); remove `.disabled(true)` / `.accessibilityRemoveTraits(.isButton)`.
- `RootSplitView.swift` `rootContent` — add `case .settings: SettingsView(database: database).environment(...)`. Full-window in detail column. Section switch resets `path`.
- Xcode filesystem-synchronized groups: new `Ari/UI/Settings/*.swift` auto-register (no pbxproj edits).

## 8. Acceptance tests (Swift Testing, written first)

**AriKitTests (Store):**
1. `SettingsRepositoryTests` — round-trip string/bool/int; `remove`; unknown key → `nil`; `all()` exact; `updatedAt` stamped. In-memory `AppDatabase.makeInMemory()`.
2. `SchemaFidelityTests` — updated `noExtraTablesYet` (+`"setting"`) + `settingSchema()` (3 columns, PK, no tombstones).

**AriViewModelsTests:**
3. `SettingsViewModelTests` — `load()` populates; toggling persists (read back); unset value → documented default, never fabricated; `setAPIKey`/`deleteAPIKey` reflect in `hasAPIKey` via `StubSecretsStoring`; key text never exposed; each honest-disabled group reports `.disabled(reason:)` with non-empty reason.
4. `CalendarSettingsViewModelTests` — no EventKit ⇒ honest `.notDetermined` + empty list; `setSelected` round-trips.

**App-target tests (xcodebuild lane):**
5. `StoreBackedSettingsReadingTests` / `StoreBackedRecallSettingsReadingTests` — stored keys map correctly; unset → `nil`, never throws for "unset".
6. `KeychainSecretStoreTests` — set/get/delete round-trip. **Integration-only:** runs under the signed xcodebuild test host; headless `swift test` covers VM logic via `StubSecretsStoring`. (DECIDED: accept integration-only.)
7. *(Optional)* `SettingsGlassAuditTest` — source-level assertion that no file under `Ari/UI/Settings/` contains `glassEffect` (glass-on-chrome-only).

No Rust-incumbent invariant suite to dual-run (net-new Swift). Bar = tests above + reviewer gate.

## 9. Invariants preserved
- **No-Fake-State:** honest-disabled controls truly `.disabled` with a real reason banner; path/index-stats/version are real data; API keys show presence only; empty calendar list honest.
- **Recall safety shell:** Settings only *configures* provider/endpoint; loopback-only, bounded context, never-invents-citations stay enforced inside `RecallEngine`. No switch to disable the shell.
- **Consent-before-record:** untouched. "Save audio recordings" is a preference, not a consent bypass.
- **Single-DB-owner:** the `setting` table lives in the one `AppDatabase`; access only via `SettingsRepository`. Secrets in Keychain, deliberately not SQLite.

## 10. Slices (workflow execution order)

**FOUNDATION slice (one implementer, build-green before any section):**
1. Store: `setting` table + `SettingRecord` + `SettingsRepository` + `AppDatabase.settings` + `SettingKey`; update `SchemaFidelityTests`; add `SettingsRepositoryTests`. Gate: `swift test` AriKit green.
2. AriViewModels: `SecretsStoring` (+ stub), the **complete** `SettingsViewModel` + `CalendarSettingsViewModel`, tests #3–#4. Gate: AriViewModels green.
3. App target: `KeychainSecretStore`, `StoreBacked{Settings,RecallSettings}Reading`, `AppEnvironment.secrets`, theme `@AppStorage`/`AppearanceStore`, conformer tests #5.
4. Routing + shell: `SidebarSection.settings`, `SettingsTab`, `RootSplitView` case, replace pinned stub, `SettingsView` shell + `SettingsCard` + `SettingsDisabledGroup` + **5 honest-minimal stub section files** (real header, no fabricated controls). Gate: app builds, Settings route navigable, sections render honest-empty.

**→ Build-green gate before the 5 section slices.** Because the VM surface + helpers exist, each section slice edits **only its one section file** — parallel-safe view-only edits:
5. `SettingsGeneralSection` · 6. `SettingsRecordingsSection` · 7. `SettingsTranscriptionSection` · 8. `SettingsSummarySection` · 9. `SettingsCalendarSection`.

**Integration/review slice:** full app build + `swift test`; light/dark + Reduce Transparency pass; glass-audit; `swift-code-reviewer` gate; update `brand/BRAND.md`/gallery only if a new primitive was added; commit.

## Open decisions — RESOLVED
- **Theme store:** `@AppStorage("appAppearance")` (instant, pre-DB, device-local). ✅
- **Default recall embedder** (apple excluded): `ollama`. ✅
- **Keychain test host:** integration-only under signed xcodebuild; headless uses `StubSecretsStoring`. ✅
