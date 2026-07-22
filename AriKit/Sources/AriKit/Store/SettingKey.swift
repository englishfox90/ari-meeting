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

    // General
    case generalShowNotch
    case generalShowInMenuBar
    case generalRecordingAlerts

    // Recordings
    case recordingsSaveAudio
    case recordingsStartNotification
    case recordingsMicDevice
    case recordingsSystemDevice
    case recordingsAudioBackend

    // Transcription
    case transcriptionProvider
    case transcriptionModel
    /// BCP-47 identifier (or the `"auto"` sentinel = system language) for the on-device
    /// SpeechTranscriber. The one real transcription knob in the Swift app — provider/model
    /// selection is gone (Apple SpeechTranscriber is the sole engine).
    case transcriptionLanguage

    // NOTE: theme is deliberately NOT here — it lives in `@AppStorage("appAppearance")`
    // (plan §2.4), not this table.
}
