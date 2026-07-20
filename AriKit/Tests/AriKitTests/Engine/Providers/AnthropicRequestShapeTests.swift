//
//  AnthropicRequestShapeTests.swift — plan §6 Slice B (dual-run gate: request-shape parity).
//
//  Captures the outgoing body via `StubURLProtocol` and asserts byte-shape parity with the Rust
//  Claude builder (`llm_client.rs:211-292`): `system` top-level, `messages: [user]` only,
//  `max_tokens` HARDCODED to 2048, and the `x-api-key`/`anthropic-version` headers (never a Bearer
//  Authorization header — `llm_client.rs:242` explicitly skips it for Claude).
//
//  Tests that touch `StubURLProtocol` run inside `ProviderTestSupport.withExclusiveNetworkStub`
//  (see `OpenAIRequestShapeTests.swift` header for why).
//
import Foundation
import Testing
@testable import AriKit

struct AnthropicRequestShapeTests {
    @Test func claudeRequestBodyMatchesAnthropicShape() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(body: ProviderTestSupport.claudeMessagesResponse(text: "ok"))
            let config = ProviderConfig(kind: .claude, model: "claude-3-opus", apiKey: "ant-key")
            let client = try AnthropicClient(config: config, session: ProviderTestSupport.stubbedSession())

            let result = try await client.generate(LLMRequest(system: "sys", user: "usr", maxTokens: 999))
            #expect(result == "ok")

            let request = try #require(StubURLProtocol.lastCapturedRequest())
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "ant-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            // ← Claude never carries a Bearer Authorization header (llm_client.rs:242).
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let json = try ProviderTestSupport.capturedJSONBody()
            #expect(json["model"] as? String == "claude-3-opus")
            #expect(json["system"] as? String == "sys")
            // ← hardcoded 2048, NOT LLMRequest.maxTokens=999 (llm_client.rs:286).
            #expect(json["max_tokens"] as? Int == 2048)
            #expect(json["stream"] == nil)
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages[0]["role"] as? String == "user")
            #expect(messages[0]["content"] as? String == "usr")
        }
    }

    @Test func generateThrowsRequestFailedOnNonSuccessStatus() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(status: 401, body: Data("unauthorized".utf8))
            let config = ProviderConfig(kind: .claude, model: "claude-3-opus", apiKey: "bad-key")
            let client = try AnthropicClient(config: config, session: ProviderTestSupport.stubbedSession())

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

    @Test func initRejectsNonClaudeConfig() {
        let config = ProviderConfig(kind: .openAI, model: "gpt-4o")
        do {
            _ = try AnthropicClient(config: config)
            Issue.record("expected .notConfigured")
        } catch LLMError.notConfigured {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
