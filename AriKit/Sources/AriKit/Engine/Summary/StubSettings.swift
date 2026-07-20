//
//  StubSettings.swift — deterministic `SettingsReading`/`SecretsReading` test doubles
//  (plan §9(1), Slice G).
//
//  `#if DEBUG`-only, mirroring `StubLLMClient` (`Engine/Providers/StubLLMClient.swift`): these
//  stand in for the eventual app-side Keychain/settings-table conformers so `SummaryService` can
//  be exercised headlessly, with no real Keychain/settings dependency built in this slice.
//
#if DEBUG
    import Foundation

    public struct StubSettingsReading: SettingsReading {
        public var ollamaEndpointValue: String?
        public var customOpenAIConfigValue: CustomOpenAIConfig?
        public var ollamaContextSizeValue: Int?
        public var mlxContextSizeValue: Int?
        public var ollamaEndpointError: LLMError?
        public var customOpenAIConfigError: LLMError?

        public init(
            ollamaEndpointValue: String? = nil,
            customOpenAIConfigValue: CustomOpenAIConfig? = nil,
            ollamaContextSizeValue: Int? = nil,
            mlxContextSizeValue: Int? = nil,
            ollamaEndpointError: LLMError? = nil,
            customOpenAIConfigError: LLMError? = nil
        ) {
            self.ollamaEndpointValue = ollamaEndpointValue
            self.customOpenAIConfigValue = customOpenAIConfigValue
            self.ollamaContextSizeValue = ollamaContextSizeValue
            self.mlxContextSizeValue = mlxContextSizeValue
            self.ollamaEndpointError = ollamaEndpointError
            self.customOpenAIConfigError = customOpenAIConfigError
        }

        public func ollamaEndpoint() async throws -> String? {
            if let ollamaEndpointError {
                throw ollamaEndpointError
            }
            return ollamaEndpointValue
        }

        public func customOpenAIConfig() async throws -> CustomOpenAIConfig? {
            if let customOpenAIConfigError {
                throw customOpenAIConfigError
            }
            return customOpenAIConfigValue
        }

        public func ollamaContextSize(forModel _: String) async -> Int? {
            ollamaContextSizeValue
        }

        public func mlxContextSize(forModel _: String) async -> Int? {
            mlxContextSizeValue
        }
    }

    public struct StubSecretsReading: SecretsReading {
        public var apiKeys: [String: String]
        public var error: LLMError?

        public init(apiKeys: [String: String] = [:], error: LLMError? = nil) {
            self.apiKeys = apiKeys
            self.error = error
        }

        public func apiKey(forProvider providerKey: String) async throws -> String? {
            if let error {
                throw error
            }
            return apiKeys[providerKey]
        }
    }
#endif
