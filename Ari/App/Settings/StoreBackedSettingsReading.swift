//
//  StoreBackedSettingsReading.swift — the app target's real `SettingsReading` conformer,
//  backed by `AppDatabase.settings` (docs/plans/settings-ui.md §2.3).
//
//  Never throws for "unset" — an absent key resolves to `nil`/the documented Rust fallback,
//  exactly like `SummaryService` already tolerates (`SummarySettings.swift`'s header).
//
import AriKit
import AriKitEngineMLX
import AriViewModels
import Foundation

struct StoreBackedSettingsReading: SettingsReading {
    let database: AppDatabase

    func ollamaEndpoint() async throws -> String? {
        try await database.settings.string(forKey: .summaryOllamaEndpoint)
    }

    func customOpenAIConfig() async throws -> CustomOpenAIConfig? {
        guard let json = try await database.settings.string(forKey: .summaryCustomOpenAIConfig),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CustomOpenAIConfig.self, from: data)
    }

    /// No Ollama HTTP context-size probe ported yet — `nil` lets `SummaryService` fall back to
    /// its documented "context fetch failed" default of 4000 (plan §2.3).
    func ollamaContextSize(forModel model: String) async -> Int? {
        nil
    }

    /// No MLX/BuiltInAI model-registry lookup ported yet — `nil` lets `SummaryService` fall back
    /// to its documented "unknown model" default of 1748.
    func mlxContextSize(forModel model: String) async -> Int? {
        nil
    }

    func summaryModelConfig() async throws -> SummaryModelConfig? {
        // The on-device Qwen (`mlx`) is the zero-config DEFAULT — mirror `SettingsViewModel.Defaults`
        // (the single source of truth) so auto-summary works out of the box before the user ever
        // opens Settings. An empty model is a VALID configuration for `.mlx` (single fixed on-device
        // model — see `ProviderFactory`), so the model must NOT gate configuration: requiring a
        // stored non-empty model here made the default provider report "notConfigured" even after it
        // was selected (the Settings UI deliberately shows no model field for on-device Qwen).
        let provider = try await database.settings.string(forKey: .summaryProvider)
            ?? SettingsViewModel.Defaults.summaryProvider
        var model = try await database.settings.string(forKey: .summaryModel)
            ?? SettingsViewModel.Defaults.summaryModel

        // On-device Qwen has a single fixed model (the Settings UI shows no model field for it), so
        // its stored model is empty by design — supply the canonical repo id so `.mlx` resolves to
        // a loadable model instead of tripping ProviderFactory's per-kind "model is required" guard.
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ProviderKind.from(provider) == .mlx {
            model = AriKitEngineMLX.defaultModelID
        }

        return SummaryModelConfig(providerKey: provider, model: model)
    }
}
