//
//  ProviderFactoryTests.swift — plan §6 Slice A + Slice B update.
//
//  Slice A's factory validates config, applies the loopback gate for `.ollama` (the load-bearing
//  invariant, plan §7), and wires the MLX injection point. Slice B adds real conformers
//  (`OpenAICompatibleClient`/`AnthropicClient`) for openAI/groq/openRouter/ollama/customOpenAI/
//  claude — only `.claudeCLI`/`.appleFoundation` (Slices C/D) and an unregistered `.mlx` still
//  honestly throw `.providerUnavailable` (No-Fake-State).
//
import Testing
@testable import AriKit

struct ProviderFactoryTests {
    @Test func nonLoopbackOllamaThrowsLoopbackViolation() {
        let config = ProviderConfig(
            kind: .ollama,
            model: "llama3",
            ollamaEndpoint: "https://ollama.example.com"
        )
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .loopbackViolation")
        } catch LLMError.loopbackViolation {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func loopbackOllamaConstructsARealOpenAICompatibleClient() throws {
        // The gate is checked BEFORE construction — a loopback endpoint must not be rejected as a
        // policy violation, and Slice B now has a real Ollama conformer.
        let config = ProviderConfig(
            kind: .ollama,
            model: "llama3",
            ollamaEndpoint: "http://localhost:11434"
        )
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .ollama)
    }

    @Test func defaultOllamaEndpointIsTreatedAsLoopbackAndConstructs() throws {
        // nil endpoint → the default local server (← LoopbackPolicy.swift / shell.rs).
        let config = ProviderConfig(kind: .ollama, model: "llama3")
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .ollama)
    }

    @Test func mlxWithoutInjectedProviderThrowsProviderUnavailable() {
        let config = ProviderConfig(kind: .mlx, model: "qwen3.5-4b-4bit")
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .providerUnavailable")
        } catch LLMError.providerUnavailable {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func mlxWithInjectedProviderReturnsTheInjectedClient() async throws {
        let config = ProviderConfig(kind: .mlx, model: "qwen3.5-4b-4bit")
        let client = try ProviderFactory.make(config: config) { resolvedConfig in
            StubLLMClient(kind: resolvedConfig.kind, cannedResponse: "mlx says hi")
        }
        #expect(client.kind == .mlx)
        let result = try await client.generate(LLMRequest(system: "s", user: "u"))
        #expect(result == "mlx says hi")
    }

    @Test func customOpenAIWithoutEndpointThrowsNotConfigured() {
        let config = ProviderConfig(kind: .customOpenAI, model: "gpt-x")
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func customOpenAIWithWhitespaceOnlyEndpointThrowsNotConfigured() {
        let config = ProviderConfig(kind: .customOpenAI, model: "gpt-x", customOpenAIEndpoint: "   ")
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func customOpenAIWithValidEndpointConstructsARealClient() throws {
        let config = ProviderConfig(
            kind: .customOpenAI,
            model: "local-model",
            customOpenAIEndpoint: "http://localhost:8080"
        )
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .customOpenAI)
    }

    @Test func emptyModelThrowsNotConfiguredRegardlessOfKind() {
        let config = ProviderConfig(kind: .openAI, model: "")
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func httpFamilyKindsNowConstructRealConformers() throws {
        // Slice B landed real conformers for the whole OpenAI-compatible family + Claude.
        for kind: ProviderKind in [.openAI, .claude, .groq, .openRouter] {
            let config = ProviderConfig(kind: kind, model: "some-model", apiKey: "key")
            let client = try ProviderFactory.make(config: config)
            #expect(client.kind == kind)
        }
    }

    @Test func remainingKindsWithoutConformersHonestlyThrowProviderUnavailable() {
        // ClaudeCLI (Slice C) has a real conformer on macOS (see
        // `claudeCLIOnMacOSConstructsARealConformer` below); on non-macOS platforms it still
        // honestly throws `.providerUnavailable` (the kind is absent from the factory there).
        // AppleFoundation (Slice D) now always constructs — see
        // `appleFoundationConstructsARealConformer` below.
        var kinds: [ProviderKind] = []
        #if !os(macOS)
            kinds.append(.claudeCLI)
        #endif
        for kind in kinds {
            let config = ProviderConfig(kind: kind, model: "some-model", apiKey: "key")
            do {
                _ = try ProviderFactory.make(config: config)
                Issue.record("expected .providerUnavailable for \(kind)")
            } catch LLMError.providerUnavailable {
                // expected — no conformer yet
            } catch {
                Issue.record("unexpected error for \(kind): \(error)")
            }
        }
    }

    @Test func appleFoundationConstructsARealConformer() throws {
        // Construction always succeeds — the on-device-availability gate runs inside `generate()`,
        // not at provider-selection time (mirrors `.claudeCLI`'s deferred binary resolution).
        let config = ProviderConfig(kind: .appleFoundation, model: "on-device")
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .appleFoundation)
    }

    #if os(macOS)
        @Test func claudeCLIOnMacOSConstructsARealConformer() throws {
            // Construction always succeeds (binary resolution is deferred to `generate`, matching
            // Rust's shape where `resolve_claude_binary` is only called inside
            // `generate_with_claude_cli`, not at provider-selection time).
            let config = ProviderConfig(kind: .claudeCLI, model: "default")
            let client = try ProviderFactory.make(config: config)
            #expect(client.kind == .claudeCLI)
        }

        @Test func claudeCLIWithEmptyModelIsExemptFromTheModelRequiredGuard() throws {
            // ← `claude_cli.rs:109-110,139-140`: an empty model means "use the CLI's configured
            // default" and is a VALID configuration for ClaudeCLI (unlike every other kind, where
            // an empty model is `.notConfigured`). The resulting client must also omit `--model`.
            let config = ProviderConfig(kind: .claudeCLI, model: "")
            let client = try ProviderFactory.make(config: config)
            #expect(client.kind == .claudeCLI)

            let arguments = ClaudeCLIClient.arguments(model: "", systemPrompt: "s", userPrompt: "u")
            #expect(!arguments.contains("--model"))
        }
    #endif
}
