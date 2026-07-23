# ari-notch

> **Status (2026-07-22): absorbed natively.** The island UI *and* its
> upcoming-meeting scheduler brain have been ported into the native Swift app —
> `Ari/UI/Notch/` (panel host + chrome) and
> `AriKit/Sources/AriViewModels/Notch/` (model, presentation, planner,
> scheduler), bound directly to `RecordingSession`/calendar state with **no
> NDJSON layer** and re-themed onto Marginalia (see
> `docs/plans/notch-panel-absorption.md`). This sidecar now serves **only the
> frozen Rust/Tauri app** and receives no new features; deletion is a Phase 5
> cleanup.

The **Ari Notch** sidecar — a standalone Swift/SwiftUI executable that renders a
**custom simulated Dynamic Island** at the top-center of the active screen for the
Ari Meeting app. It is bundled by Tauri as an `externalBin` sidecar and driven over
**stdin/stdout NDJSON**.

The island is drawn by **our own AppKit host** (`IslandPanelController`) + SwiftUI
chrome (`IslandContainerView`) — **no external UI dependency**. DynamicNotchKit was
dropped (WS-H): on a non-notched display it fell back to a detached floating
capsule instead of the integrated island we want. Our host draws a black
island that **fuses with the physical notch** when the active screen has one and
**simulates a black pill** when it doesn't — uniformly across single-laptop,
external-monitor, and multi-screen setups.

The wire-protocol `Codable` layer is **WS-A/E**; the recording HUD (UC2) is
**WS-C**; the upcoming-meeting alert (UC1) is **WS-G**; the Rust bridge is **WS-B**.

> **Build status.** Compiled and tested during authoring with the present
> toolchain (Apple Swift 6.3.3, `arm64-apple-macosx26.0`): `swift test` →
> **47/47 passing** (37 content/protocol + 10 new island geometry/presentation),
> and `swift build -c release --arch arm64` produces a working `arm64` Mach-O.
> The **live visual look of the island has NOT been run here** (no display) — the
> human must validate it via `pnpm run app:local` in the signed `.app`.

---

## Build & stage the sidecar

Requires a full Xcode toolchain (Swift 5.9+, macOS 14+ SDK) on Apple Silicon.

```bash
# From this directory (ari-notch/):
swift build -c release --arch arm64

# Stage it where Tauri expects the sidecar (target-triple suffix is mandatory):
BIN="$(swift build -c release --arch arm64 --show-bin-path)/ari-notch"
mkdir -p ../frontend/src-tauri/binaries
cp "$BIN" ../frontend/src-tauri/binaries/ari-notch-aarch64-apple-darwin
```

`frontend/scripts/run-local.sh` (`pnpm run app:local`) does this automatically on
first run — it builds `ari-notch` and copies it to
`frontend/src-tauri/binaries/ari-notch-aarch64-apple-darwin` if that file is
missing, exactly like it already does for `llama-helper`.

### `tauri:dev` note

`ari-notch` is now listed in `tauri.conf.json` → `bundle.externalBin`. Tauri
validates that every `externalBin` exists at build time, so — just like
`llama-helper` — the sidecar must be staged **before** `pnpm run tauri:dev`.
`scripts/tauri-auto.js` was deliberately left unchanged (it stages no sidecars
today); run the build+stage commands above once, or use `pnpm run app:local`,
before `tauri:dev`.

---

## Run the tests (conformance guarantee)

```bash
# From this directory (ari-notch/):
swift test
```

`Tests/AriNotchTests/ProtocolTests.swift` decodes **every** shared fixture in
`frontend/src-tauri/src/notch/fixtures/*.json` and asserts each maps to the
expected case, then asserts the outbound `action` encoding is FLAT
(`{"type":"action","action":"record_event","event_id":"EVT-123"}`). This is the
cross-language conformance check against the Rust source of truth
(`frontend/src-tauri/src/notch/protocol.rs`).

**Fixtures are referenced in place, not copied.** The test resolves the fixtures
directory relative to its own source file via `#filePath`, walking up four levels
to the repo root and into `frontend/src-tauri/src/notch/fixtures`. If WS-A edits a
fixture, this test sees the change immediately — a single source of truth. If the
package is ever moved relative to `frontend/`, update the path math in
`fixturesDir`.

The test target imports the executable target via `@testable import ari_notch`
(the SwiftPM module name for `ari-notch` — hyphen becomes underscore). Testing an
executable target is supported since Swift 5.5; the package floor is 5.9.

---

## Platform floor

- **macOS 14+** (`Package.swift` → `platforms: [.macOS(.v14)]`). Required by SwiftUI
  `@Observable` / the Observation framework AND `UnevenRoundedRectangle` (the
  island shape, macOS 14+). This is far below the Ari app's macOS 26 runtime floor,
  so it adds no constraint to the shipped product.
- **Apple Silicon (arm64) only**, matching the app's target and the
  `-aarch64-apple-darwin` sidecar suffix.
- **No external Swift package dependencies.** `Package.resolved` is absent because
  nothing is pinned — the island host is built entirely on AppKit + SwiftUI.

---

## The custom island host (WS-H)

DynamicNotchKit was **removed**. The island is now hosted by two files we own:

- **`IslandPanelController.swift`** — a `@MainActor` class owning ONE borderless
  `NSPanel`:
  - `styleMask = [.borderless, .nonactivatingPanel]`, `isOpaque = false`,
    `backgroundColor = .clear`, `hasShadow = true`.
  - **Level:** one above the status-window level
    (`CGWindowLevelForKey(.statusWindow) + 1`), NOT `.statusBar` — `.statusBar` is
    the menu bar's own level and can render *under* the menu bar on notched Macs,
    clipping the island. `+1` reliably draws over the menu bar / notch.
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
    .ignoresCycle]` — shows on every Space, floats over fullscreen apps, never
    appears in window-cycling.
  - **Clicks without focus theft:** `ignoresMouseEvents = false`, and we show with
    `orderFrontRegardless()` — **never** `makeKeyAndOrderFront`. A
    `.nonactivatingPanel` routes clicks to its controls (Pause/Stop/Record) while
    the user's frontmost app keeps focus.
  - **Active-screen follow:** re-anchors top-center of `NSScreen.main` (the screen
    with the active window) on `didChangeScreenParametersNotification` and
    `NSWorkspace.didActivateApplicationNotification`, and continuously as the
    SwiftUI island resizes. Positioning uses `screen.frame` (NOT `visibleFrame`) so
    the island hugs the very top edge over the menu bar.
- **`IslandContainerView.swift`** — the black island CHROME: a custom `Shape`
  (`IslandShape`) with **square top corners (flush to the top edge)** and **large
  rounded bottom corners**, springing between a **collapsed** minimal pill
  (notch-sized when a notch exists, so it merges; a small centered pill otherwise)
  and an **expanded** state that hosts `NotchRootView` (HUD or alert). It reports
  its rendered size up to the controller so the panel follows the morph.
- **`IslandGeometry.swift`** — PURE, AppKit-free math (`islandFrame`, `notchWidth`,
  and the `IslandPresentation` mapping) covered by
  `Tests/AriNotchTests/IslandGeometryTests.swift`.

---

## Tokens duplicated from `DESIGN.json` — drift risk

The web visual-system test (`frontend/tests/lib/visual-system.test.mjs`) covers
the **web UI only**. Any brand token hardcoded in Swift is therefore invisible to
that test and can silently drift from `DESIGN.json`. Track them here.

| Token | Value | Where | Status |
|-------|-------|-------|--------|
| Arivo Amber (Signal-Rule accent) | `#E8A020` | `NotchStyle.swift` → `NotchPalette.amber` | **In use.** REC dot (when actively recording) + the single primary action (**Stop** / **Record**) fill ONLY — the accent surfaces, kept ≤8%. Never on labels/timer/transcript/audio meter/open-app button. |
| Warm cream ink (primary text) | `#F5EFE6` | `NotchStyle.swift` → `NotchPalette.ink` | **In use.** Elapsed timer, meeting title, transcript body, glass-button + circle-icon label text. Warm neutral, not cool gray. |
| Warm taupe muted ink (secondary) | `#A89F90` | `NotchStyle.swift` → `NotchPalette.mutedInk` | **In use.** REC/PAUSED + UPCOMING eyebrow, speaker tag, countdown/attendees, audio-meter bar fill. |

These three brand tokens are the single Swift source of truth in
`NotchStyle.swift` (consumed by `RecordingHUDView.swift` WS-C and
`UpcomingMeetingView.swift` WS-G, plus the shared button styles + `AudioMeterView`
there). They are invisible to the web visual-system test — keep them in sync with
`DESIGN.json`. Amber lands on the REC dot + the single primary action only (Signal
Rule, ≤8%); secondary controls are translucent glass (`.ultraThinMaterial`), the
audio meter and the hover open-app button are muted/ink, never amber. If you add
another hardcoded token, append a row here.

---

## Files

| File | Role |
|------|------|
| `Package.swift` | SwiftPM manifest — executable `ari-notch` + `AriNotchTests`, macOS 14 floor, **no external dependencies**. |
| `Sources/AriNotch/Protocol.swift` | `Codable` mirror of the WS-A wire protocol. Decodes the shared fixtures; encodes the flat `action` shape; unknown `type` → `.unknown`. |
| `Sources/AriNotch/NotchModel.swift` | `@Observable @MainActor` model folding inbound messages into UI state. |
| `Sources/AriNotch/NotchRootView.swift` | Content router: UC1 alert vs UC2 HUD off the model (moved out of `main.swift`, logic unchanged). |
| `Sources/AriNotch/RecordingHUDView.swift` | UC2 recording HUD (WS-C). Reused verbatim inside the island. |
| `Sources/AriNotch/UpcomingMeetingView.swift` | UC1 prompt-to-record alert (WS-G). Reused verbatim inside the island. |
| `Sources/AriNotch/IslandGeometry.swift` | **PURE** geometry + presentation math (AppKit-free, unit-tested). |
| `Sources/AriNotch/IslandContainerView.swift` | Black island chrome (square-top / rounded-bottom shape, collapsed↔expanded spring). |
| `Sources/AriNotch/IslandPanelController.swift` | AppKit host: borderless nonactivating `NSPanel`, top-center active-screen follow. |
| `Sources/AriNotch/PlaceholderView.swift` | Neutral scaffold placeholder (unused by the island; retained, harmless). |
| `Sources/AriNotch/main.swift` | Entry point: stdin NDJSON reader thread → model on main actor; notch detection + `ready`; builds + shows `IslandPanelController`; stdout writer. |
| `Tests/AriNotchTests/ProtocolTests.swift` | Decodes every shared fixture; asserts the flat `action` wire shape. |
| `Tests/AriNotchTests/IslandGeometryTests.swift` | Unit tests for centering (incl. multi-monitor offsets), notch-width, and presentation mapping. |
