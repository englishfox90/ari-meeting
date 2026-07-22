//
//  StoreBackedRecallSettingsReading.swift — the app target's real `RecallSettingsReading`
//  conformer, backed by `AppDatabase.settings` (docs/plans/settings-ui.md §2.3).
//
import AriKit
import Foundation

struct StoreBackedRecallSettingsReading: RecallSettingsReading {
    let database: AppDatabase

    func modelConfig() async throws -> RecallModelConfig? {
        guard let provider = try await database.settings.string(forKey: .summaryProvider),
              let model = try await database.settings.string(forKey: .summaryModel) else {
            return nil
        }
        let endpoint = try await database.settings.string(forKey: .summaryOllamaEndpoint)
        return RecallModelConfig(provider: provider, model: model, ollamaEndpoint: endpoint)
    }
}
