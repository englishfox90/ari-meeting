//
//  ProviderStreamingTests.swift — plan §6 Slice B (streaming path parity).
//
//  Exercises the REAL `stream(_:)` implementations of both HTTP conformers end-to-end through
//  `StubURLProtocol` — not just the pure `SSELineDecoder` helper (`SSEDeltaExtractionTests.swift`)
//  or the non-streaming `generate()` path (`OpenAIRequestShapeTests.swift` /
//  `AnthropicRequestShapeTests.swift`). Asserts (a) the outgoing request body carries
//  `"stream": true` (← `llm_stream.rs:167,174`), and (b) the yielded deltas accumulate to the
//  expected text via `URLSession.bytes(for:)` + `SSELineDecoder`.
//
//  Tests that touch `StubURLProtocol` run inside `ProviderTestSupport.withExclusiveNetworkStub`
//  (see `OpenAIRequestShapeTests.swift` header for why).
//
import Foundation
import Testing
@testable import AriKit

struct ProviderStreamingTests {
    @Test func openAIStreamSetsStreamTrueAndYieldsAccumulatedDeltas() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            let sse = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: [DONE]

            """
            StubURLProtocol.stub(body: Data(sse.utf8))
            let config = ProviderConfig(kind: .openAI, model: "gpt-4o", apiKey: "sk-test")
            let client = try OpenAICompatibleClient(config: config, session: ProviderTestSupport.stubbedSession())

            var accumulated = ""
            for try await delta in client.stream(LLMRequest(system: "sys", user: "usr")) {
                accumulated += delta
            }
            #expect(accumulated == "Hello world")

            let json = try ProviderTestSupport.capturedJSONBody()
            #expect(json["stream"] as? Bool == true)
            let request = try #require(StubURLProtocol.lastCapturedRequest())
            #expect(request.timeoutInterval == 300)
        }
    }

    @Test func claudeStreamSetsStreamTrueAndYieldsAccumulatedDeltas() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            let sse = """
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}

            data: [DONE]

            """
            StubURLProtocol.stub(body: Data(sse.utf8))
            let config = ProviderConfig(kind: .claude, model: "claude-3-opus", apiKey: "ant-key")
            let client = try AnthropicClient(config: config, session: ProviderTestSupport.stubbedSession())

            var accumulated = ""
            for try await delta in client.stream(LLMRequest(system: "sys", user: "usr")) {
                accumulated += delta
            }
            #expect(accumulated == "Hi there")

            let json = try ProviderTestSupport.capturedJSONBody()
            #expect(json["stream"] as? Bool == true)
            let request = try #require(StubURLProtocol.lastCapturedRequest())
            #expect(request.timeoutInterval == 300)
        }
    }

    @Test func openAIStreamThrowsRequestFailedOnNonSuccessStatus() async throws {
        try await ProviderTestSupport.withExclusiveNetworkStub {
            StubURLProtocol.reset()
            StubURLProtocol.stub(status: 500, body: Data("server exploded".utf8))
            let config = ProviderConfig(kind: .openAI, model: "gpt-4o", apiKey: "sk-test")
            let client = try OpenAICompatibleClient(config: config, session: ProviderTestSupport.stubbedSession())

            do {
                for try await _ in client.stream(LLMRequest(system: "sys", user: "usr")) {
                    Issue.record("expected no deltas before the thrown error")
                }
                Issue.record("expected .requestFailed")
            } catch LLMError.requestFailed {
                // expected
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}
