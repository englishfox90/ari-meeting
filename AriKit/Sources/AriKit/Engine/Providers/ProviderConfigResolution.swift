//
//  ProviderConfigResolution.swift — shared provider/model/key/endpoint resolution (Phase 3.4
//  Track H locked decision §6-7, `arikit-engine-extras.md`).
//
//  Lifted out of `SummaryService` (← `ari-engine/src/summary/service.rs:344-471`) into one
//  behavior-preserving helper both `SummaryService` and `PersonExtraction`/`PersonReconciliation`
//  call — a reviewable de-dup, not a behavior change. `SummaryService` keeps its own
//  `resolveTokenThreshold` (Summary-specific: Persons never chunks by token budget, it bounds by
//  a flat 48k-char transcript cap instead, `extraction.rs:28`).
//
//  `resolve` widened to `public` (docs/plans/swift-meeting-generation-flow.md, Track 1 §0): every
//  prior caller (`SummaryService`, `PersonExtraction`/`PersonReconciliation`) lived inside this
//  same `AriKit` module, so `internal` sufficed until now. `SummaryRunner` (the `AriViewModels`
//  target) needs the identical resolution the plan specifies rather than a second, drifting copy
//  — a cross-module reuse, not a behavior change.
//
import Foundation

public enum ProviderConfigResolution {
    /// ← the keyless-provider set (`service.rs:353`): these providers don't require an API key
    /// from the standard settings column (Ollama/MLX are local; CustomOpenAI has its own key
    /// field; ClaudeCLI/AppleFoundation authenticate outside this layer entirely).
    static let keylessProviders: Set<ProviderKind> = [
        .ollama, .mlx, .customOpenAI, .claudeCLI, .appleFoundation
    ]

    /// Resolves a full `ProviderConfig` for a raw `providerKey`/`modelName` against the injected
    /// `SettingsReading`/`SecretsReading` seams. Throws `LLMError.notConfigured` for every
    /// "can't proceed" case (unsupported provider key, missing API key, unconfigured Custom
    /// OpenAI) — callers that must degrade gracefully instead of hard-failing (Persons
    /// extraction/reconciliation) catch `LLMError` at the call site rather than letting it become
    /// a thrown error for "nothing useful happened" (← `extraction.rs:53-55`); `SummaryService`
    /// (which DOES propagate it as a caller-facing error) is unaffected.
    public static func resolve(
        providerKey: String,
        modelName: String,
        settings: any SettingsReading,
        secrets: any SecretsReading
    ) async throws -> ProviderConfig {
        guard let providerKind = ProviderKind.from(providerKey) else {
            throw LLMError.notConfigured("Unsupported provider: \(providerKey)")
        }

        let apiKey = try await resolveAPIKey(providerKind: providerKind, providerKey: providerKey, secrets: secrets)
        let ollamaEndpoint = providerKind == .ollama ? try? await settings.ollamaEndpoint() : nil

        var customOpenAIEndpoint: String?
        var maxTokens: Int?
        var temperature: Double?
        var topP: Double?
        var finalAPIKey = apiKey

        if providerKind == .customOpenAI {
            let config = try await resolveCustomOpenAIConfig(settings: settings)
            customOpenAIEndpoint = config.endpoint
            finalAPIKey = config.apiKey ?? ""
            maxTokens = config.maxTokens
            temperature = config.temperature
            topP = config.topP
        }

        return ProviderConfig(
            kind: providerKind,
            model: modelName,
            apiKey: finalAPIKey,
            ollamaEndpoint: ollamaEndpoint,
            customOpenAIEndpoint: customOpenAIEndpoint,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
    }

    private static func resolveAPIKey(
        providerKind: ProviderKind,
        providerKey: String,
        secrets: any SecretsReading
    ) async throws -> String {
        guard !keylessProviders.contains(providerKind) else {
            return ""
        }
        let key: String?
        do {
            key = try await secrets.apiKey(forProvider: providerKey)
        } catch {
            throw LLMError.notConfigured("Failed to retrieve API key for \(providerKey): \(error)")
        }
        guard let key, !key.isEmpty else {
            throw LLMError.notConfigured("API key not found for \(providerKey)")
        }
        return key
    }

    private static func resolveCustomOpenAIConfig(settings: any SettingsReading) async throws -> CustomOpenAIConfig {
        do {
            guard let config = try await settings.customOpenAIConfig() else {
                throw LLMError.notConfigured("Custom OpenAI provider selected but no configuration found")
            }
            return config
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.notConfigured("Failed to retrieve custom OpenAI config: \(error)")
        }
    }
}
