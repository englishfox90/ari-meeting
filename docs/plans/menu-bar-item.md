# Menu bar item (Swift port of the Rust tray)

Ports the frozen Tauri app's menu-bar item (`frontend/src-tauri/src/tray.rs`) to the native Swift
app as a SwiftUI `MenuBarExtra`. Closes the "notifications/menu bar" half of S7
(`docs/plans/arikit-native-shell.md` §567) and lights up the Settings "Show in menu bar" toggle,
which shipped **honest-disabled** ("There is no menu-bar item in the Swift app yet").

## What it does

A menu-bar (top-of-screen) item that, in one click, lets the owner:

- **Start / stop a recording** — driven by the app-wide `RecordingSession`. Honest to the Swift
  session model: Start when idle; Stop when recording; a disabled "Starting…/Stopping…" status
  during transitions. **No Pause/Resume** — the Rust tray had them, but the Swift `RecordingSession`
  has no pause phase yet, so surfacing them would be Fake-State.
- **See upcoming meetings** and record one pre-named — reuses `CalendarBriefViewModel` +
  `CalendarBriefSection` verbatim (the same "happening now / about to start" brief Home shows). A
  per-event **Record** primes the title + calendar link and starts immediately, exactly like the
  meeting-reminder action (product decision 2026-07-22, `AppEnvironment.startRecordingFromReminder`).
- **Open the app**, jump to **Settings**, and **Quit**.

The item is **additive and opt-in** (default off), matching the Rust tray (`default_menu_bar_enabled
== false` on macOS). The normal Dock/windowed app is unchanged.

## Design

### Visibility preference → `@AppStorage`, not the `setting` table

The scene that inserts/removes a `MenuBarExtra` must read the preference **reactively at app-scene
scope**, before/independent of the DB. That is exactly the constraint that put **theme** in
`@AppStorage` rather than the `setting` table (`SettingKey` note; `AppearanceStore`). Menu-bar
visibility is the same shape: a device-local UI preference, never a sync candidate — and the Rust
app itself stored it in a local prefs file (`app-preferences.json`), **not** the meeting DB. So we
retire the DB key `.generalShowInMenuBar` and mirror `AppearanceStore` with a new
`MenuBarVisibilityStore` over `UserDefaults` key `"showInMenuBar"`:

- `AriApp` gates the `MenuBarExtra` scene with `@AppStorage(MenuBarVisibilityStore.defaultsKey)`.
  `@AppStorage` is KVO-backed on `.standard`, so toggling the Settings control re-evaluates the
  scene and inserts/removes the status item live — the same mechanism theme already uses.
- `SettingsViewModel` exposes `menuBar: MenuBarVisibilityStore` (like `appearance`); the Settings
  toggle binds through it. `menuBarAvailability` flips `.disabled → .live`.

### Reused seams (no new capability at the wrong layer)

- `CalendarBriefViewModel` / `CalendarBriefSection` — upcoming-meetings list + Record handoff.
  The panel builds the VM once the shell is ready and reloads via `.task(id:)`; `load()` re-filters
  against a fresh `now`, so a since-passed meeting drops off whenever the task re-runs. A snapshot
  that lags one reopen is still honest — every row is a real DB event, never fabricated.
- `RecordingSession` — the app-wide, mount-independent recording brain (start/stop/state).
- `AppEnvironment.startRecordingFromReminder(eventId:)` — the prime-and-start-immediately path,
  reused for event Record; a new sibling `startRecordingFromMenuBar()` covers the no-event Start.
- `AppEnvironment.pendingNavigation` — routes the just-mounted shell to `.newMeeting` / `.settings`.

### App activation

`MenuBarContentView` activates the app (`NSApp.activate`) and fronts the existing content window,
or `openWindow(id:)`s a fresh one when all windows are closed (menu-bar-only state). Activating the
app moves focus off the popover, which dismisses it — no manual dismiss plumbing.

## Files

New:
- `AriKit/Sources/AriViewModels/Support/MenuBarVisibilityStore.swift`
- `Ari/UI/MenuBar/MenuBarContentView.swift`

Changed:
- `Ari/App/AriApp.swift` — `MenuBarExtra` scene gated on `@AppStorage`; `mainWindowID` for reopen.
- `Ari/App/AppEnvironment.swift` — `startRecordingFromMenuBar()` (no-event Start).
- `AriKit/Sources/AriViewModels/SettingsViewModel.swift` — menu-bar → store; `menuBarAvailability = .live`.
- `AriKit/Sources/AriKit/Store/SettingKey.swift` — retire `.generalShowInMenuBar` (note it).
- `Ari/UI/Settings/SettingsGeneralSection.swift` — toggle binds to the store; live description.

## Tests / invariants

- `MenuBarVisibilityStore` round-trips through `UserDefaults`, defaults `false`.
- `SettingsViewModel.menuBarAvailability == .live` (mirrors `deviceSelectionIsLive`); drop it from
  the `disabledGroupsCarryNonEmptyReasons` list.
- `SettingKey` no longer carries `generalShowInMenuBar` (mirrors the `recordingsSystemDevice`
  retirement test).
- **No-Fake-State:** empty brief → no upcoming section (already `CalendarBriefSection`'s contract);
  no Pause/Resume; disabled Record while active/pre-bootstrap.
- **Consent-before-record:** every start still goes through `requestStart()` +
  `confirmConsentRequested()` (the sole capture edge) — a menu click is the explicit initiation,
  never a silent auto-record.
