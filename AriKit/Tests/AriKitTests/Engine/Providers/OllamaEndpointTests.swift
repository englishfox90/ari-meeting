//
//  OllamaEndpointTests.swift — plan §6 Slice B.
//
//  ← the Ollama arm of the `match provider` (`llm_client.rs:194-202`): default host
//  `http://localhost:11434` when unset, a custom endpoint used verbatim otherwise — plus the
//  loopback gate (§7), which is `ProviderFactory`'s job, not the client's.
//
import Testing
@testable import AriKit

struct OllamaEndpointTests {
    @Test func defaultEndpointWhenNilUsesLocalhost() throws {
        let config = ProviderConfig(kind: .ollama, model: "llama3")
        let url = try OpenAICompatibleClient.resolveBaseURL(for: config)
        #expect(url.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func customEndpointIsUsedVerbatim() throws {
        let config = ProviderConfig(kind: .ollama, model: "llama3", ollamaEndpoint: "http://localhost:9999")
        let url = try OpenAICompatibleClient.resolveBaseURL(for: config)
        #expect(url.absoluteString == "http://localhost:9999/v1/chat/completions")
    }

    @Test func loopbackIsEnforcedByTheFactoryBeforeConstruction() {
        // The client itself doesn't police loopback — ProviderFactory does, ahead of construction
        // (plan §7); a non-loopback endpoint must never reach a real HTTP client.
        let config = ProviderConfig(kind: .ollama, model: "llama3", ollamaEndpoint: "https://remote.example.com")
        do {
            _ = try ProviderFactory.make(config: config)
            Issue.record("expected .loopbackViolation from the factory gate")
        } catch LLMError.loopbackViolation {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func factoryConstructsARealOllamaClientForALoopbackEndpoint() throws {
        let config = ProviderConfig(kind: .ollama, model: "llama3", ollamaEndpoint: "http://127.0.0.1:11434")
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .ollama)
    }

    @Test func factoryConstructsARealOllamaClientForTheDefaultLoopbackEndpoint() throws {
        let config = ProviderConfig(kind: .ollama, model: "llama3")
        let client = try ProviderFactory.make(config: config)
        #expect(client.kind == .ollama)
    }
}
