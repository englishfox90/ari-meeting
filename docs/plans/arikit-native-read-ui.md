# AriKit — Native macOS Read UI (Phase 2, slice S6) — plan

> **STATUS: PLAN / IN PROGRESS.** This is the S6 detail promised by `docs/plans/arikit-native-shell.md`
> (§11 S6); the DECIDED block there sequenced it FIRST (after S0 + S8-lite import), ahead of the
> capture vertical.
>
> **Open decisions RESOLVED (2026-07-20):** (1) VM test lane = **new `AriViewModels` package product**
> + `AriViewModelsTests` (headless `swift test`; mirrors the `AriCapture` split). (2) Button-style
> home = **`AriKit/DesignSystem`** (shared, parity-testable). (3) Audio path = **`<audioReference.path>/audio.mp4`**
> with an honest `.missing` fallback; reconcile with S8's audio-file adoption before S6d closes.

## 1. Goal & seam

**Goal.** Replace the S0 placeholder `ContentView` (`Ari/App/ContentView.swift`) with the real native
macOS read UI — a `NavigationSplitView` host over Meetings / People / Series, driven entirely from
`AriKit` repositories, Marginalia-themed, with native `AVPlayer` audio playback in the meeting
detail. This is the visible payoff of the migration: the first screen where the owner *sees* their
real (imported) library in a first-party Mac app.

**Seam & phase.** Phase 2, slice S6. It attaches to the **Store seam** (already cut and landed —
`AppDatabase` + repositories exist and pass round-trip/single-owner suites) on the **target Swift
side**: S6 is a pure *reader* of the landed Store. It touches no Rust, no capture, no engine write
path.

**Net-new vs. port.** S6 is **net-new Swift host code**, not a port. There is no incumbent Swift
reader to beat; the honesty bar is No-Fake-State + visual-system parity, not audio equivalence.

**In scope:** Meetings list + detail (transcript, summary, notes render, audio playback), People
list + detail, Series list + detail (ledger render), the `NavigationSplitView` host, the shared
component layer, and the Marginalia button system. **Out of scope for S6:** Ask/recall UI (sidebar
reserves a slot, ships no screen), calendar UI (S7), block editing (Phase 4 — S6 renders
`notesMarkdown` read-only, never `notesJson`), any write/edit flow, any recording UI (S1–S5).

## 2. Module & file layout

Two homes, split by the test-lane decision (§6): view models in a new **`AriViewModels` package
library** (headless `swift test`), SwiftUI views + AVPlayer glue in the `Ari` app target
(`xcodebuild`). Mirrors the `AriCapture` isolation precedent.

### 2.1 New `AriKit` package product — `AriViewModels` (macOS + iOS)

```
AriKit/Sources/AriViewModels/          (library; depends on AriKit only; imports Observation, NOT SwiftUI/AVFoundation)
├─ Support/
│  └─ LoadState.swift                  enum LoadState<Value: Sendable>: loading / loaded(Value) / empty / failed(String)
├─ MeetingsListViewModel.swift
├─ MeetingDetailViewModel.swift
├─ PeopleListViewModel.swift
├─ PersonDetailViewModel.swift
├─ SeriesListViewModel.swift
└─ SeriesDetailViewModel.swift
```

View models depend only on `AppDatabase` + the `Sendable` repository structs. They need `@Observable`
(from `Observation`) and `Foundation`; they do NOT import SwiftUI or AVFoundation, so they compile
and test headlessly via `swift test`. `Package.swift` adds the product + target + `AriViewModelsTests`,
all `.swiftLanguageMode(.v6)`.

### 2.2 App target — `Ari/UI/` (SwiftUI views, `xcodebuild` lane)

```
Ari/UI/
├─ AppShell/
│  ├─ RootSplitView.swift          NavigationSplitView host; replaces ContentView as WindowGroup root
│  ├─ SidebarSection.swift          enum { meetings, people, series }  (ask: reserved, not built in S6)
│  ├─ SidebarView.swift             List(selection:) of sections, SF Symbol per section
│  └─ LaunchStatusView.swift        launching/importing/failed states (extracted from ContentView)
├─ MeetingsList/
│  └─ MeetingsListView.swift
├─ MeetingDetails/
│  ├─ MeetingDetailView.swift       sections: Transcript · Summary · Notes
│  ├─ TranscriptListView.swift      speaker-labelled, timecode-tappable lines
│  ├─ SummaryView.swift             MarkdownText render of Summary.bodyMarkdown
│  ├─ NotesReadView.swift           MarkdownText render of MeetingNote.notesMarkdown (read-only)
│  ├─ AudioPlayerBar.swift          transport + scrubber
│  └─ AudioPlayerController.swift   @MainActor @Observable AVPlayer wrapper (app target)
├─ People/
│  ├─ PeopleListView.swift
│  └─ PersonDetailView.swift
├─ Series/
│  ├─ SeriesListView.swift
│  └─ SeriesDetailView.swift
└─ Components/
   ├─ CardRow.swift                 shared list-row primitive (title + metadata + trailing chevron)
   ├─ SectionHeader.swift           uppercase-caption section header (.caption ramp)
   ├─ StateContainer.swift          renders a LoadState honestly: ProgressView / empty copy / error copy
   └─ MarkdownText.swift            Text(AttributedString(markdown:)) with honest fallback on parse failure
```

The Marginalia **button system lands in `AriKit/Sources/AriKit/DesignSystem/`** (shared, parity-tested,
already imports SwiftUI) — see §4.

### 2.3 View-model public surface

`LoadState` is the No-Fake-State spine — `.empty` is first-class, distinct from `.loaded([])`:

```swift
public enum LoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case empty          // honest "nothing here yet" — not a spinner, not fake rows
    case failed(String) // the real error text, never a fake ready
}
```

Each VM is `@MainActor @Observable final class`, constructed with `AppDatabase` (single owner,
injected from `AppEnvironment`), never opening its own connection:

```swift
@MainActor @Observable
public final class MeetingsListViewModel {
    public private(set) var state: LoadState<[Meeting]> = .loading
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }
    public func observe() async            // consumes database.meetings.observeAll()
}

@MainActor @Observable
public final class MeetingDetailViewModel {
    public private(set) var meeting: LoadState<Meeting> = .loading
    public private(set) var transcript: [Transcript] = []           // ordered by audioStartTime
    public private(set) var summary: Summary?                        // nil → honest "No summary yet"
    public private(set) var notes: MeetingNote?                      // nil → honest "No notes"
    public private(set) var participants: [Person] = []
    public private(set) var speakerNames: [SpeakerID: String] = [:]
    public private(set) var audio: AudioAvailability = .unresolved
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }
    public func load(_ id: MeetingID) async
    public func displayName(for speakerId: SpeakerID?) -> String?
}

public enum AudioAvailability: Sendable, Equatable {
    case unresolved
    case available(URL)
    case missing(String)   // honest reason: "Recording file not found at <path>"
}
```

`PeopleListViewModel` (`state: LoadState<[Person]>`, marks `isOwner`), `PersonDetailViewModel`
(`person`, participant `meetings`), `SeriesListViewModel` (`state: LoadState<[Series]>`),
`SeriesDetailViewModel` (`series`, `memberMeetings`, honest nil `ledgerMarkdown`).

**Load pattern.** List VMs consume `repository.observeAll()` in `.task` for live updates; detail VMs
do one-shot `find`/`forMeeting` reads. All reads `async throws`; a thrown error maps to
`.failed(String(describing: error))`. All data through repositories only (single-DB-owner).

Data sources per screen: meetings list `meetings.observeAll()`; meeting detail `meetings.find`,
`transcripts.forMeeting`, `summaries.forMeeting`, `meetingNotes.find`, `persons.participants(inMeeting:)`,
`speakers.all()` (build `[SpeakerID: label]`); people `persons.all()`/`find`/`owner()`; series
`series.all()`/`find` (ledger-hydrated) / `series.meetingIds(inSeries:)`.

## 3. @Observable-MVVM discipline & AppEnvironment injection

- **One `@MainActor @Observable` VM per screen.** NOT TCA. Views are value-type SwiftUI; each owns
  its VM as `@State` and injects `environment.database` at construction.
- **`AppEnvironment` is the injection root** (already `@MainActor @Observable`, already the single
  `AppDatabase` owner). `RootSplitView` reads `@Environment(AppEnvironment.self)` and, once
  `status == .ready`, unwraps `environment.database` to build child VMs. Before ready it renders
  `LaunchStatusView`. VMs never touch `AppEnvironment` directly (they take `AppDatabase`), staying
  app-target-free and testable.
- **Explicit loading/empty/error** via `LoadState` + `StateContainer` (No-Fake-State).

## 4. The Marginalia button system

New file `AriKit/Sources/AriKit/DesignSystem/MarginaliaButtonStyle.swift`. Four roles × two sizes:

```swift
public enum MarginaliaButtonRole: Sendable { case primary, secondary, quiet, recording }
public enum MarginaliaButtonSize: Sendable {
    case regular   // 26pt (toolbar/inline)
    case large     // 32pt (dialog/HUD)
    public var controlHeight: CGFloat { switch self { case .regular: 26; case .large: 32 } }
}
public struct MarginaliaButtonStyle: ButtonStyle { /* role + size + scheme */ }
public extension ButtonStyle where Self == MarginaliaButtonStyle { /* .marginalia(_:_:in:) sugar */ }
```

Role → `MarginaliaColorRole` (resolved via `Color.marginalia(_:in:)`):

| Role | Fill | Label | Stroke | Pressed |
|------|------|-------|--------|---------|
| **primary** | `.accent` solid | `.surface` | none | `.accentPressed` |
| **secondary** | `.elevated` tonal | `.inkBody` | `.hairline` 1px | `.selectionWash` overlay |
| **quiet** | clear | `.accent` (or `.inkSecondary` neutral) | none | `.selectionWash` |
| **recording** | `.recordingRed` solid | `.surface` | none | darkened red |

Radius `.control` (6pt); press animation gated on Reduce Motion by the caller. "Exactly one Primary
per view" is a reviewer-checklist invariant (`MarginaliaRules.accentSolidFillExclusive`), not statically
enforceable. Add a plain-data `MarginaliaButtonSpec` (role → color-role + height) — the analog of
`MarginaliaTypeSpec` — so the parity test asserts the mapping without introspecting an opaque style.

**Roles actually used in S6 (read-only):** **quiet** (timecode seek, transport, "Copy summary") and
**secondary** (Transcript/Summary/Notes switcher, "Reveal in Finder"). **Primary** appears zero or
once (read UI has no primary CTA; zero is valid). **Recording** specced but never rendered in S6.

## 5. Audio playback

Native `AVPlayer` in `AudioPlayerController` (app target — AVFoundation), a small `@MainActor
@Observable` wrapper: `play()`, `pause()`, `seek(toSeconds:)`, `currentTime`, `isPlaying`. **No
byte-range bridge** — `AVPlayer(url:)` reads the local file directly.

**URL resolution.** `Meeting.audioReference` wraps the recording *folder*; the audio file is
`<audioReference.path>/audio.mp4`. `MeetingDetailViewModel.load` resolves it and `fileExists` →
`.available(URL)` or `.missing(reason)`. Imported-by-reference meetings may not resolve → honest
"Recording file not found," never a dead scrubber. `nil` reference → bar absent.

Transcript-line seek: tap a line's timecode → `controller.seek(toSeconds: transcript.audioStartTime ?? 0)`.
`@ref(MM:SS)`/`[MM:SS]` badges in the summary are an optional nice-to-have via the already-verifying
`SummaryCitations`/`Citations`; render verified refs as tappable seek runs, only when `audio == .available`.
Interactive block-editor badges stay deferred to Phase 4.

## 6. Navigation model

**3-column `NavigationSplitView`** (sidebar → list → detail) — the Mail/Notes idiom, scales as Ask +
Calendar join later. `RootSplitView` holds `@State selectedSection` + per-section selection, all
value-based. Detail drills down with a `NavigationStack` per section (Series → member meeting; Person
→ meeting). Sidebar rows: SF Symbols only (`list.bullet.rectangle`, `person.2`,
`arrow.triangle.2.circlepath`). An **Ask** slot is reserved in the enum but not rendered in S6.
Frameless/unified title bar already set on the `WindowGroup`.

## 7. Acceptance tests (written first)

**Test lane: `AriViewModels` package + `swift test` (Lane 1, agent-runnable).** VMs are pure of
SwiftUI/AVFoundation and depend only on `AppDatabase.makeInMemory()` + `Sendable` repositories.
Reserve `xcodebuild`/XcodeBuildMCP (Lane 2) for visual parity and AVPlayer playback.

### Lane 1 — headless `swift test`
- (a) **`MarginaliaButtonStyleParityTests`** (`AriKitTests`) — role→color-role and size→26/32pt mapping,
  mirroring `MarginaliaTokenParityTests`.
- (b) **VM suites** (`AriViewModelsTests`, over `AppDatabase.makeInMemory()` + `ModelSamples` fixtures):
  `MeetingsListViewModelTests` (loaded/order, honest `.empty`, `.failed`); `MeetingDetailViewModelTests`
  (resolve; honest nil summary/notes; transcript order; speaker-name resolution); `MeetingDetailAudioTests`
  (`.available` vs honest `.missing` vs absent bar); `PeopleListViewModelTests` (owner flagged; `.empty`);
  `SeriesDetailViewModelTests` (ledger present/absent honest; member meetings resolve);
  `SingleOwnerReadTests` (all VMs read one shared store).

### Lane 2 — ad-hoc `.app` via XcodeBuildMCP (no TCC/cert needed for read-only)
Visual-system parity by eye (navy accent ≤8%, warm grounds, SF Symbols, no emoji, frameless title
bar); read flows on imported data; play + seek from a transcript timecode; honest missing audio.

## 8. Invariants preserved
- **No-Fake-State** — `LoadState.empty`/`.failed` explicit; missing summary/notes/ledger honest;
  missing audio an honest reason; real `meetingCount`. Enforced by Lane-1 empty/nil/missing asserts.
- **Single-DB-owner** — every read via `AppEnvironment`'s one `AppDatabase`; no VM/view opens SQLite.
  Enforced by `SingleOwnerReadTests`.
- **Swift 6 strict concurrency** — VMs `@MainActor`; repositories cross as `Sendable` structs;
  `LoadState`/`AudioAvailability` `Sendable`; `AriViewModels` pins `.v6`. No `@unchecked Sendable`.
- **Recall safety shell** — not touched (no Ask UI); the read-only `@ref` path reuses the verifying
  `Citations`/`SummaryCitations`, so it cannot surface an unverified timestamp.

## 9. Dependency-ordered slices
- **S6a — Host + button system + components (foundation).** `MarginaliaButtonStyle` + `MarginaliaButtonSpec`,
  `LoadState`, `AriViewModels` product in `Package.swift`, `RootSplitView` + `SidebarView` +
  `SidebarSection` + `LaunchStatusView`, `Components/`. `RootSplitView` becomes the `WindowGroup` root.
  *Accept:* Lane-1 `MarginaliaButtonStyleParityTests` green; Lane-2 3-column shell renders, sidebar
  switches, launch/import/failed still honest.
- **S6b — Meetings list.** `MeetingsListViewModel` + view (observe-backed). *Accept:* list/empty/error
  tests; Lane-2 imported meetings render `createdAt`-desc.
- **S6c — Meeting detail (text).** `MeetingDetailViewModel` + detail view; transcript, summary, notes.
  *Accept:* detail-resolve + honest-nil tests; Lane-2 all three panels show.
- **S6d — Audio playback.** `AudioPlayerController` + bar; timecode seek; optional verified `@ref`.
  *Accept:* `AudioAvailability` tests; Lane-2 play + seek + honest missing.
- **S6e — People.** VMs + views (owner flagged; participant meetings). Parallelizable after S6a.
- **S6f — Series.** VMs + views (ledger render, member meetings). Parallelizable after S6a.

Order: **S6a → S6b → S6c → S6d**; **S6e/S6f** after S6a.

**Risks:** VM-home churn (fallback: app-target + `xcodebuild test`); audio path assumption
(`<folder>/audio.mp4` — degrades safely to `.missing`; reconcile with S8); markdown fidelity
(`AttributedString(markdown:)` ≠ BlockNote exactly; acceptable read-only, falls back to plain text);
WIP limit (S6 is one slice of the single active Phase 2).
