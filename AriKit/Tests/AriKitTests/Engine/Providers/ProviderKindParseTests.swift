//
//  ProviderKindParseTests.swift — plan §6 Slice A.
//
//  1:1 port of `LLMProvider::from_str` (`llm_client.rs:84`), including the legacy
//  `builtin-ai`/`local-llama`/`localllama` aliases now mapping to `.mlx`.
//
import Testing
@testable import AriKit

struct ProviderKindParseTests {
    @Test func parsesKnownProvidersCaseInsensitively() {
        #expect(ProviderKind.from("openai") == .openAI)
        #expect(ProviderKind.from("OpenAI") == .openAI)
        #expect(ProviderKind.from("OPENAI") == .openAI)
        #expect(ProviderKind.from("claude") == .claude)
        #expect(ProviderKind.from("Claude") == .claude)
        #expect(ProviderKind.from("groq") == .groq)
        #expect(ProviderKind.from("Groq") == .groq)
        #expect(ProviderKind.from("ollama") == .ollama)
        #expect(ProviderKind.from("Ollama") == .ollama)
        #expect(ProviderKind.from("openrouter") == .openRouter)
        #expect(ProviderKind.from("OpenRouter") == .openRouter)
        #expect(ProviderKind.from("custom-openai") == .customOpenAI)
        #expect(ProviderKind.from("Custom-OpenAI") == .customOpenAI)
        #expect(ProviderKind.from("claude-cli") == .claudeCLI)
        #expect(ProviderKind.from("Claude-CLI") == .claudeCLI)
        #expect(ProviderKind.from("apple-foundation") == .appleFoundation)
        #expect(ProviderKind.from("Apple-Foundation") == .appleFoundation)
    }

    @Test func legacyBuiltInAliasesMapToMLX() {
        // Rust mapped these to the now-retired `BuiltInAI`; the Swift successor is `.mlx`.
        #expect(ProviderKind.from("builtin-ai") == .mlx)
        #expect(ProviderKind.from("BUILTIN-AI") == .mlx)
        #expect(ProviderKind.from("local-llama") == .mlx)
        #expect(ProviderKind.from("localllama") == .mlx)
        #expect(ProviderKind.from("LocalLlama") == .mlx)
    }

    @Test func unknownProviderReturnsNil() {
        #expect(ProviderKind.from("not-a-provider") == nil)
        #expect(ProviderKind.from("") == nil)
        #expect(ProviderKind.from("gpt-4") == nil)
    }

    @Test func allCasesAreCovered() {
        // Every declared case has at least one accepted spelling.
        #expect(ProviderKind.allCases.count == 9)
    }

    @Test func settingIDRoundTripsThroughFrom() {
        // The persisted token MUST parse back to the same case — the picker persists `settingID`
        // and both it and the engine re-resolve via `from(_:)`. `rawValue` does NOT satisfy this
        // (e.g. "claudeCLI"), which was the Claude-CLI-resets-to-default bug.
        for kind in ProviderKind.allCases {
            #expect(ProviderKind.from(kind.settingID) == kind)
        }
    }

    @Test func apiKeyAndModelOverrideCapabilities() {
        // On-device engines need no key and expose no model override.
        #expect(ProviderKind.mlx.requiresAPIKey == false)
        #expect(ProviderKind.claudeCLI.requiresAPIKey == false)
        #expect(ProviderKind.ollama.requiresAPIKey == false)
        #expect(ProviderKind.openAI.requiresAPIKey == true)
        #expect(ProviderKind.claude.requiresAPIKey == true)

        #expect(ProviderKind.mlx.allowsModelOverride == false)
        #expect(ProviderKind.appleFoundation.allowsModelOverride == false)
        #expect(ProviderKind.claudeCLI.allowsModelOverride == true)
        #expect(ProviderKind.openAI.allowsModelOverride == true)
    }
}
