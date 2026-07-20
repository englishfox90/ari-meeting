//
//  ProviderConfig.swift — resolved, per-backend provider configuration (plan §2.2).
//
//  ← the settings reads scattered through `ari-engine/src/summary/service.rs` (model/api-key/
//  endpoint resolution that happens before dispatch into `generate_summary`), collapsed into one
//  value the caller resolves once and hands to `ProviderFactory.make(config:)`.
//
import Foundation

public struct ProviderConfig: Sendable {
    public var kind: ProviderKind
    public var model: String
    /// "" for keyless providers (Ollama / MLX / ClaudeCLI / AppleFoundation).
    public var apiKey: String
    public var ollamaEndpoint: String?
    public var customOpenAIEndpoint: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(
        kind: ProviderKind,
        model: String,
        apiKey: String = "",
        ollamaEndpoint: String? = nil,
        customOpenAIEndpoint: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.kind = kind
        self.model = model
        self.apiKey = apiKey
        self.ollamaEndpoint = ollamaEndpoint
        self.customOpenAIEndpoint = customOpenAIEndpoint
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}
