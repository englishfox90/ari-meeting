//
//  OpenAIRequestShapeTests.swift — plan §6 Slice B (dual-run gate: request-shape parity).
//
//  Captures the outgoing body via `StubURLProtocol` and asserts byte-shape parity with the Rust
//  builders (`llm_client.rs:181-292`): `messages: [system, user]`, and ONLY `.customOpenAI`
//  carries `max_tokens`/`temperature`/`top_p` (`llm_client.rs:260`).
//
//  Tests that touch `StubURLProtocol` run inside `ProviderTestSupport.withExclusiveNetworkStub` —
//  its captured-request storage is necessarily class-scoped (`URLProtocol` registers a type, not
//  an instance), so concurrently-running tests must not share it unguarded.
//
import Foundation
import Testing
@testable import AriKit

struct OpenAIRequestShapeTests {
    @Test func openAIRequestOnlyCarriesSystemAndUserNoTunableParams() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(body: ProviderTestSupport.chatCompletionResponse(content: "ok"))
            let config = ProviderConfig(kind: .openAI, model: "gpt-4o", apiKey: "sk-test")
            let client = try OpenAICompatibleClient(config: config, session: ProviderTestSupport.stubbedSession())

            let result = try await client.generate(
                LLMRequest(system: "sys", user: "usr", maxTokens: 222, temperature: 0.1, topP: 0.2)
            )
            #expect(result == "ok")

            let request = try #require(StubURLProtocol.lastCapturedRequest())
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let json = try ProviderTestSupport.capturedJSONBody()
            #expect(json["model"] as? String == "gpt-4o")
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] as? String == "system")
            #expect(messages[0]["content"] as? String == "sys")
            #expect(messages[1]["role"] as? String == "user")
            #expect(messages[1]["content"] as? String == "usr")
            // ← ONLY CustomOpenAI applies max_tokens/temperature/top_p (llm_client.rs:260).
            #expect(json["max_tokens"] == nil)
            #expect(json["temperature"] == nil)
            #expect(json["top_p"] == nil)
            // ← `generate` never sets `stream` (only `generate_summary_stream` does, llm_stream.rs:172).
            #expect(json["stream"] == nil)
            // ← Rust's `REQUEST_TIMEOUT_DURATION = Duration::from_secs(300)` (llm_client.rs:8,301).
            #expect(request.timeoutInterval == 300)
        }
    }

    @Test func customOpenAIAppliesTunableParamsFromTheRequest() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(body: ProviderTestSupport.chatCompletionResponse(content: "ok"))
            let config = ProviderConfig(
                kind: .customOpenAI, model: "local-model", customOpenAIEndpoint: "http://localhost:8080"
            )
            let client = try OpenAICompatibleClient(config: config, session: ProviderTestSupport.stubbedSession())

            _ = try await client.generate(
                LLMRequest(system: "sys", user: "usr", maxTokens: 256, temperature: 0.4, topP: 0.8)
            )

            let request = try #require(StubURLProtocol.lastCapturedRequest())
            #expect(request.url?.absoluteString == "http://localhost:8080/chat/completions")

            let json = try ProviderTestSupport.capturedJSONBody()
            #expect(json["max_tokens"] as? Int == 256)
            #expect(json["temperature"] as? Double == 0.4)
            #expect(json["top_p"] as? Double == 0.8)
        }
    }

    @Test func customOpenAIEndpointTrimsAllTrailingSlashes() throws {
        // ← Rust's `trim_end_matches('/')` strips ALL trailing slashes (llm_client.rs:207).
        let config = ProviderConfig(kind: .customOpenAI, model: "m", customOpenAIEndpoint: "http://localhost:8080///")
        let client = try OpenAICompatibleClient(config: config)
        #expect(client.baseURL.absoluteString == "http://localhost:8080/chat/completions")
    }

    @Test func groqAndOpenRouterUseDistinctBaseURLs() throws {
        let groq = try OpenAICompatibleClient(config: ProviderConfig(kind: .groq, model: "m"))
        #expect(groq.baseURL.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
        let openRouter = try OpenAICompatibleClient(config: ProviderConfig(kind: .openRouter, model: "m"))
        #expect(openRouter.baseURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    }

    @Test func generateThrowsRequestFailedOnNonSuccessStatus() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(status: 500, body: Data("server exploded".utf8))
            let config = ProviderConfig(kind: .openAI, model: "gpt-4o", apiKey: "sk-test")
            let client = try OpenAICompatibleClient(config: config, session: ProviderTestSupport.stubbedSession())

            do {
                _ = try await client.generate(LLMRequest(system: "sys", user: "usr"))
                Issue.record("expected .requestFailed")
            } catch LLMError.requestFailed {
                // expected
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}
