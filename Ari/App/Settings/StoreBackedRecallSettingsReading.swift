//
//  StoreBackedRecallSettingsReading.swift — the app target's real `RecallSettingsReading`
//  conformer, backed by `AppDatabase.settings` (docs/plans/settings-ui.md §2.3).
//
import AriKit
import AriKitEngineMLX
import AriViewModels
import Foundation

struct StoreBackedRecallSettingsReading: RecallSettingsReading {
    let database: AppDatabase

    func modelConfig() async throws -> RecallModelConfig? {
        // Recall reuses the summary provider/model. It MUST resolve the same way
        // `StoreBackedSettingsReading.summaryModelConfig()` does — otherwise Ask reports
        // `.modelNotConfigured` for the zero-config on-device Qwen default even though summaries
        // work. Two traps: (1) the default provider/model may never have been written to the store
        // (the default just works, the user never touched Settings), and (2) on-device Qwen (`.mlx`)
        // has a single fixed model, so the Settings UI shows no model field and stores an EMPTY
        // model by design — a naive `guard let model` here returned nil / an unloadable empty model.
        let provider = try await database.settings.string(forKey: .summaryProvider)
            ?? SettingsViewModel.Defaults.summaryProvider
        var model = try await database.settings.string(forKey: .summaryModel)
            ?? SettingsViewModel.Defaults.summaryModel

        // Empty model + `.mlx` → supply the canonical repo id so the provider resolves to a loadable
        // model instead of tripping the per-kind "model is required" guard (mirrors the summary path).
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ProviderKind.from(provider) == .mlx {
            model = AriKitEngineMLX.defaultModelID
        }

        let endpoint = try await database.settings.string(forKey: .summaryOllamaEndpoint)
        return RecallModelConfig(provider: provider, model: model, ollamaEndpoint: endpoint)
    }
}
