//
//  SettingKey.swift — the typed key space for the key-value `setting` table
//  (docs/plans/settings-ui.md §2.1).
//
//  A plain `String`-backed enum, not a typed ID: `setting.key` is the primary key itself (no
//  synthetic row id), so the raw value IS the storage key. `CaseIterable` lets
//  `SettingsRepository.all()` / tests enumerate the whole key space without hand-maintaining a
//  parallel list.
//
import Foundation

public enum SettingKey: String, Sendable, CaseIterable {
    // Summary (plan §2.1)
    case summaryProvider
    case summaryModel
    case summaryOllamaEndpoint
    /// JSON-encoded `CustomOpenAIConfig` blob.
    case summaryCustomOpenAIConfig
    case summaryLanguage
    case summaryAutomatic

    /// Recall
    case recallEmbedder

    /// General
    case generalRecordingAlerts
    // NOTE: `.generalShowInMenuBar` was retired (docs/plans/menu-bar-item.md) — menu-bar
    // visibility is a device-local UI preference read at app-scene scope to gate the
    // `MenuBarExtra`, so it moved to `UserDefaults`/`@AppStorage` (via `MenuBarVisibilityStore`),
    // exactly like theme (see the theme note below). Any orphaned rows from an older build are
    // simply unread.

    /// Notifications (the Swift-native port — calendar reminders + summary-ready alerts).
    /// Whether a "meeting starts soon" reminder fires ahead of each synced calendar event.
    case notificationsMeetingReminders
    /// Minutes-before-start the reminder fires, stored as a plain decimal string ("1"/"5"/"10"/…).
    /// A string (not a dedicated int column) because `SettingsRepository` is a string/bool KV store;
    /// callers parse with `Int.init` and fall back to the honest default on an unparseable value.
    case notificationsReminderLeadMinutes
    /// Whether a notification is delivered when a summary finishes generating AND that generation
    /// took longer than the "long summary" threshold (the user has likely tabbed away by then).
    case notificationsSummaryReady

    // Recordings
    case recordingsSaveAudio
    case recordingsStartNotification
    /// Whether tapping Record first shows the consent-before-record prompt. Defaults OFF (a
    /// private, single-user tool in a one-party-consent jurisdiction): the Record action is itself
    /// the explicit edge into capture, so a second confirmation is friction. Turning it ON restores
    /// the two-step consent gate for two-party-consent situations. This is a preference over a
    /// preserved capability — the consent machinery/tests still exist, just un-defaulted.
    case recordingsRequireConsent
    /// Stores a stable CoreAudio `kAudioDevicePropertyDeviceUID`
    /// (docs/plans/settings-audio-devices.md §4) — a real value binds into `MicrophoneCapture` at
    /// recording start; it never encodes a mere display name.
    case recordingsMicDevice
    // NOTE: `.recordingsSystemDevice` was retired (settings-audio-devices.md decision B) — system
    // audio is a single global Core Audio process tap anchored to the default output device, so a
    // persisted per-device selection could never take effect. `.recordingsAudioBackend` was
    // likewise retired — Core Audio is the only capture backend on Apple, so there was never a
    // second option to select. Any orphaned rows from an older build are simply unread.

    // Transcription
    case transcriptionProvider
    case transcriptionModel
    /// BCP-47 identifier (or the `"auto"` sentinel = system language) for the on-device
    /// SpeechTranscriber. The one real transcription knob in the Swift app — provider/model
    /// selection is gone (Apple SpeechTranscriber is the sole engine).
    case transcriptionLanguage

    // NOTE: theme is deliberately NOT here — it lives in `@AppStorage("appAppearance")`
    // (plan §2.4), not this table.

    /// Whether the first-run model-install/education flow has been completed or explicitly
    /// dismissed (docs/plans/onboarding-install-flow.md §4). Absent (nil) means "never shown" —
    /// distinguished from `false`, which this flow never actually writes (it writes `true` only
    /// on completion/dismissal, mirroring `SettingsRepository`'s honest-absence pattern: an
    /// unknown/absent key returns nil, this repository never fabricates a default). "Skip for
    /// now" writes `true` too (resolved 2026-07-23: never re-nag).
    case onboardingCompleted
}
