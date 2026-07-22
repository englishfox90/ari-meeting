# Plan: Audio device enumeration + selection (Swift capture stack)

**Status: PLAN (2026-07-22).** Plan-only; executed by `swift-implementer`, gated by `swift-code-reviewer`. Lane-2 (device) verification is a human step in the signed `.app`.

**Open decisions — SETTLED (2026-07-22):**
- **A → `AriKit`.** `CoreAudioDeviceEnumerator` lives in `AriKit` alongside the seam type + protocol (SpeechAssetProviding precedent; zero `SettingsView`/`RootSplitView` wiring change).
- **B → retire `.recordingsSystemDevice`.** A persisted system-device selection can never take effect (single global tap) → No-Fake-State. Drop the `SettingKey` case + `systemDevice`/`setSystemDevice`.
- **C → human runs Lane 2.** Steps 4–5 need a signed `.app` + one-time TCC grant; device capture is not agent-closeable.

## 1. Goal & seam

Replace the honest-disabled "Default Devices" controls in Settings › Recordings (`Ari/UI/Settings/SettingsRecordingsSection.swift:60-83`, driven by `SettingsViewModel.deviceSelectionAvailability = .disabled(...)`, `AriKit/Sources/AriViewModels/SettingsViewModel.swift:83-85`) with a **real, end-to-end microphone picker** that actually binds the chosen input device into the Swift capture graph, plus an **honest read-only "current default output" row** for system audio.

**Seam / phase.** Phase 3.2 capture engine on the Swift side of the audio cut seam. Extends the landed `AriCapture` device classes (`MicrophoneCapture`, `SystemAudioTap`, `CaptureCoordinator`) and the shipped native Settings screen (`docs/plans/settings-ui.md`). No Rust/React code is touched.

**Port, not net-new.** Device enumeration + selection is a frozen Rust subsystem ported to the Swift side (Tauri app already ships it: `DeviceSelection.tsx`, `start_recording_with_devices_and_meeting`'s `micDeviceName`/`systemDeviceName`). Porting off Rust is allowed; adding to the frozen Rust app is not.

**Deliberate behavioral difference.** The Rust app had a system-audio device picker. On the Swift `SystemAudioTap`, system audio is a single global Core Audio process tap anchored to `defaultOutputDeviceID()` (`SystemAudioTap.swift:86-95`); there is no per-device selection. The Swift system-audio control becomes an **honest read-only row**, not a picker.

## 2. Module & surface

Dependency rule (hard): `AriViewModels` must **not** depend on `AriCapture`. The seam type + protocol live in `AriKit` (which everyone depends on), following the **`SpeechAssetProviding`/`SpeechAssetManager` precedent**: protocol + concrete Apple-framework-backed impl in `AriKit`, VM defaults to the concrete and stubs it in tests.

### 2.1 New public types

**`AriKit/Sources/AriKit/Capture/AudioInputDevice.swift`** (new — shared seam type):

```swift
public struct AudioInputDevice: Sendable, Identifiable, Equatable {
    public let uid: String   // CoreAudio kAudioDevicePropertyDeviceUID — STABLE across launches/reconnect
    public let name: String  // kAudioObjectPropertyName / kAudioDevicePropertyDeviceNameCFString
    public var id: String { uid }
    public init(uid: String, name: String)
}
```

**`AriKit/Sources/AriKit/Capture/AudioDeviceProviding.swift`** (new — injectable seam, mirrors `SpeechAssetProviding`):

```swift
public protocol AudioDeviceProviding: Sendable {
    /// Real input devices, stable UID + display name. Honest empty on failure/none (never fabricated).
    func inputDevices() async -> [AudioInputDevice]
    /// Human name of the current default OUTPUT device (what SystemAudioTap follows), or nil if unresolved.
    func defaultOutputDeviceName() async -> String?
}
```

**`AriKit/Sources/AriKit/Capture/CoreAudioDeviceEnumerator.swift`** (new — concrete, `#if os(macOS)`, `import CoreAudio`). Stateless `struct: AudioDeviceProviding, Sendable`. Methods are **nonisolated `async`** so synchronous CoreAudio HAL calls run off the caller's (main) actor on the cooperative pool.
- `inputDevices()` enumerates via `kAudioHardwarePropertyDevices` (HAL, **not** `AVCaptureDevice.DiscoverySession` — see R1), filters to devices with input channels (`kAudioDevicePropertyStreamConfiguration`, input scope, channels > 0), reads each device's UID + name.
- `defaultOutputDeviceName()` resolves `kAudioHardwarePropertyDefaultOutputDevice` then reads its name — same recipe as `SystemAudioTap.defaultOutputDeviceID()` + `stringProperty(objectID:selector:)` (`SystemAudioTap.swift:188-222`). Those are `private static` in `SystemAudioTap`; duplicate the small helpers rather than widening its surface.
- **Static resolver** `static func resolveDeviceID(uid: String) -> AudioObjectID?` via `kAudioHardwarePropertyTranslateUIDToDevice` — what `MicrophoneCapture` (in `AriCapture`, which depends on `AriKit`) calls to turn a persisted UID into a live `AudioObjectID`. `nil` = device not currently present.
- iOS (`#else`): returns `[]` / `nil`.

### 2.2 `AriCapture` — `MicrophoneCapture` gains device binding

`AriKit/Sources/AriCapture/MicrophoneCapture.swift` (actor):
- New actor state `private var preferredDeviceUID: String?` and setter `public func setPreferredDeviceUID(_ uid: String?)`.
- `installTapAndStart` (`:99-138`) is the shared start + rebuild path (called from `start()` and `handleConfigurationChange`), so applying the device there satisfies "survive the config-change rebuild" automatically. Revised ordering (see R2 — `setDeviceID` on the shared input/output AU leaves `outputFormat(forBus:0)` at 0 channels unless re-prepared):
  1. If `preferredDeviceUID` set → `CoreAudioDeviceEnumerator.resolveDeviceID(uid:)`; if found, `try? engine.inputNode.auAudioUnit.setDeviceID(id)`. If `nil` (unplugged) or the set throws → **log an honest notice, fall through to system default** (do not throw, do not clear the persisted UID — a replug re-selects on next rebuild/recording).
  2. `engine.reset()` then `engine.prepare()` **before** reading the format.
  3. `let format = inputNode.outputFormat(forBus: 0)`; keep the existing `sampleRate > 0, channelCount > 0` guard (`:102-104`).
  4. `installTap(... format:)` + `engine.start()` as today.
- The crash-preserving lesson at `:9` (use the hardware's own `outputFormat`; forcing a format crashes) is **preserved** — we only reorder `prepare()` ahead of the read.

### 2.3 App glue — `LiveCaptureService` threads the persisted UID in

`Ari/Capture/LiveCaptureService.swift`:
- `init` gains `preferredMicDeviceUID: @Sendable () async -> String?` (default `{ nil }` for the source-probe path). Keep existing `microphone`/`coordinator` construction.
- In `start()`, **before** `coordinator.start()`: `await microphone.setPreferredDeviceUID(preferredMicDeviceUID())`. Because `microphone` is the same actor wired into the coordinator's `micDriver`, `micDriver.start()` → `microphone.start()` → `installTapAndStart` applies it. The idle-probe path (`sourceStatus()` only, never `start()`) is unaffected.

`Ari/App/AppEnvironment.swift` — wire the provider (the `makeCaptureService` closure gains the async provider closure, capturing the already-owned `db`):
```swift
makeCaptureService: { folder in
    LiveCaptureService(
        meetingFolder: folder,
        preferredMicDeviceUID: { await db.settings.string(forKey: .recordingsMicDevice) }
    )
},
```
End-to-end seam: Settings persists UID → `AppEnvironment` reads it at recording start → `LiveCaptureService` applies it to `MicrophoneCapture` → `installTapAndStart` binds AUHAL → config-change rebuild re-applies it.

### 2.4 `SettingsViewModel` surface (`AriKit/Sources/AriViewModels/SettingsViewModel.swift`)

- New dependency `private let audioDevices: AudioDeviceProviding`, injected in `init` with default `= CoreAudioDeviceEnumerator()` (like `speechAssets: SpeechAssetProviding = SpeechAssetManager()`). No `SettingsView`/`RootSplitView` change.
- New published state (`@Observable`, `@MainActor`):
  - `public private(set) var audioInputDevices: [AudioInputDevice] = []`
  - `public private(set) var defaultOutputDeviceName: String?` (nil = honestly unresolved)
- `deviceSelectionAvailability` flips from the `.disabled(...)` `let` to `= .live`.
- `micDevice` now stores/returns the **device UID** (was always `nil` in the Swift app → no in-Swift migration). `setMicDevice(_:)` mechanically unchanged.
- Add computed `public var micDeviceIsPresent: Bool` = `micDevice == nil || audioInputDevices.contains { $0.uid == micDevice }` — lets the view honestly flag a stored-but-absent device (also covers a stale legacy device *name*: an unknown string reads as "not present" and capture falls back to default).
- New `public func refreshAudioDevices() async { audioInputDevices = await audioDevices.inputDevices(); defaultOutputDeviceName = await audioDevices.defaultOutputDeviceName() }`. Call at end of `load()` and from "Refresh Devices".
- Remove `systemDevice`, `setSystemDevice`, and the `.recordingsSystemDevice` `SettingKey` case (decision B). No-op migration (orphaned row unread).

### 2.5 View (`Ari/UI/Settings/SettingsRecordingsSection.swift`)

- **Microphone**: remove the `SettingsDisabledGroup` wrapper (now `.live`). `Picker(selection: micDeviceBinding)` lists a "System Default" row (`tag(String?.none)`) + `ForEach(viewModel.audioInputDevices) { Text($0.name).tag(Optional($0.uid)) }`. If `!viewModel.micDeviceIsPresent`, append one honest disabled row for the stored-but-absent device. **Keep `.labelsHidden()` + the `MarginaliaMenuLabel` chevron fix untouched** (already landed).
- **System Audio**: replace the `Picker` with a read-only row — `Text(viewModel.defaultOutputDeviceName ?? "Current output device unavailable")` + caption "System audio always follows your Mac's default output device." No control, no binding.
- **Refresh Devices**: `Button("Refresh Devices") { Task { await viewModel.refreshAudioDevices() } }` (keep `.marginalia(.quiet, .regular)`).
- Delete `systemDeviceBinding`/`systemDeviceDisplayName`. `micDeviceDisplayName` maps UID→name via `audioInputDevices`.
- New `AriKit/Capture/*.swift` files are inside the existing `AriKit` target; app files auto-register via Xcode filesystem-synchronized groups.

## 3. Concurrency model

- **`AudioInputDevice`** — `Sendable` value type (posture of `PCMWindow`).
- **`CoreAudioDeviceEnumerator`** — stateless `Sendable` struct; `nonisolated async` methods run synchronous CoreAudio HAL off the main actor. No new `@unchecked Sendable`.
- **`MicrophoneCapture`** — stays an `actor`; `preferredDeviceUID` is actor-isolated; resolve + `setDeviceID` + `prepare()` run inside `installTapAndStart` on the actor's executor (off main). The realtime tap block is unchanged — binding happens at graph-setup time, never on the hot audio thread.
- **Seam closure** — `preferredMicDeviceUID: @Sendable () async -> String?` captures the `Sendable` `AppDatabase`; the async read happens once, at start, before `coordinator.start()`.

## 4. Persistence

- **No schema change.** Reuses `.recordingsMicDevice` via `SettingsRepository` (`string`/`setString`/`remove`). Stored value semantics change from (unused) name → **stable CoreAudio device UID**.
- **Single-DB-owner (principle 3)** preserved — all reads/writes through `AppDatabase.settings`; `AriCapture` still writes zero DB rows.
- **`.recordingsSystemDevice` retired** (decision B) — removing a `SettingKey` case; orphaned row unread.

## 5. Acceptance tests (written first)

Lane split mirrors `MicrophoneCapture.swift:14-16`: device capture + real TCC/CoreAudio can't run under headless `swift test` (Lane 2); everything over an injected stub is Lane 1.

### Lane 1 — headless `swift test` (agent-runnable, red → green first)

`AriViewModelsTests/SettingsViewModelTests` (in-memory `AppDatabase` + new `StubAudioDeviceProviding` mirroring `StubSpeechAssetProviding`):
1. `deviceSelectionAvailability == .live`.
2. `refreshAudioDevices()` + `load()` populate `audioInputDevices` + `defaultOutputDeviceName` from the stub.
3. Empty provider is honest — `[]` / `nil`, no crash, no fabricated device entry.
4. `setMicDevice(uid)` persists to `.recordingsMicDevice`; `setMicDevice(nil)` removes it (read back via fresh `database.settings.string(...)`).
5. Stored-but-absent device is honest — persist a UID not in the stub list → `micDevice` still returns it (never silently cleared) and `micDeviceIsPresent == false`.
6. `AudioInputDevice` is `Identifiable` by `uid`, `Equatable`, `Sendable` (compiles across an actor boundary).
7. `SchemaFidelityTests` (or the `SettingKey` key-space test) drops `recordingsSystemDevice`.
8. Persisted-UID → capture seam — set `.recordingsMicDevice` in-memory, assert the `preferredMicDeviceUID` provider reads exactly that UID (spy/extracted-helper), proving end-to-end plumbing.

### Lane 2 — signed `.app`, one-time human TCC grant (Paul)

A. `inputDevices()` returns real devices with stable UIDs + human names; `defaultOutputDeviceName()` matches the macOS Sound pref.
B. Select a non-default input, record → captured audio genuinely comes from that device.
C. Config-change re-apply — connect/disconnect AirPods mid-recording; after the rebuild the chosen device is re-selected (not reset to default).
D. Chosen device unplugged → honest fallback to default, logged, no crash, persisted UID untouched (replug re-selects on next start).
E. Read-only system row updates to the new default-output name after `refreshAudioDevices()` when the Mac's default output changes.

No numeric eval / no S1–S4 gate applies (this is downstream integration, not a scored spike). Bar = qualitative Lane-2 checklist A–E.

## 6. Invariants preserved

- **No-Fake-State** — enumeration is real HAL data or honestly empty; stored-but-absent device surfaced, never silently kept; system-audio row shows the real default-output name or is honestly absent; chosen-but-unplugged device falls back with a log, never a green readout over a dead device.
- **Consent-before-record** — untouched; device selection only changes *which* mic feeds the graph.
- **Hot-path discipline** — device binding is graph-setup-time only; realtime tap/IOProc + windowing loop unchanged.
- **Single-DB-owner** — persistence stays behind `SettingsRepository`.
- **`AriViewModels` ⊥ `AriCapture`** — preserved by putting type + protocol in `AriKit`, defaulting VM to the `AriKit` concrete.

## 7. Risks & sequencing

**Risks**
- **R1 — macOS 26 `AVCaptureDevice.DiscoverySession` returns zero audio devices (HAL works).** Mitigation: enumerate via HAL (`kAudioHardwarePropertyDevices`) — the plan's choice regardless. Re-check on GA SDK during Lane 2.
- **R2 — `setDeviceID` → 0-channel format.** `inputNode.auAudioUnit == outputNode.auAudioUnit`; setting the device without re-preparing leaves `outputFormat(forBus:0)` at 0 channels. Mitigation: §2.2 ordering (`setDeviceID` → `reset()` → `prepare()` → read format → install tap → start). Version-sensitive; pin on real hardware in Lane 2. Fallback if 0 channels persists: let `installTap` use the bus's own format (nil), weighed against the crash-avoidance note — a Lane-2 decision.
- **R3 — shared input/output AU.** Setting the input device may move the output on the shared AU. Engine is input-only, so expected-harmless; verify in Lane 2 (B).
- **R4 — legacy imported device *name* as UID.** Handled for free — unknown string reads as "not present" and capture falls back to default. No special-casing.

**Sequencing** (each step independently testable; Lane 1 fully agent-closeable before hardware):
1. `AudioInputDevice` + `AudioDeviceProviding` in `AriKit`; `StubAudioDeviceProviding` in tests. → Lane 1 test 6.
2. `SettingsViewModel` surface. → Lane 1 tests 1–5, 7.
3. `SettingsRecordingsSection` view rework. → visual.
4. `CoreAudioDeviceEnumerator` (HAL enumeration + default-output name + UID resolver), `#if os(macOS)`. → Lane 2 A/E.
5. `MicrophoneCapture` device binding + revised ordering; `LiveCaptureService` + `AppEnvironment` wiring. → Lane 1 test 8, Lane 2 B/C/D.

## Files this plan touches

New: `AriKit/Sources/AriKit/Capture/AudioInputDevice.swift`, `.../AudioDeviceProviding.swift`, `.../CoreAudioDeviceEnumerator.swift`; `StubAudioDeviceProviding` in `AriKit/Tests/AriViewModelsTests/`.
Edited: `AriKit/Sources/AriCapture/MicrophoneCapture.swift`, `Ari/Capture/LiveCaptureService.swift`, `Ari/App/AppEnvironment.swift`, `AriKit/Sources/AriViewModels/SettingsViewModel.swift`, `Ari/UI/Settings/SettingsRecordingsSection.swift`, `AriKit/Sources/AriKit/Store/SettingKey.swift` (retire `recordingsSystemDevice`).

Apple-framework sources: AVAudioEngine -10877 on macOS 26 beta (HAL works); `auAudioUnit.setDeviceID` for input-device selection; 0-channel `outputFormat` after device change.
