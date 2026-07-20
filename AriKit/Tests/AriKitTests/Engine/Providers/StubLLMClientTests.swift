//
//  StubLLMClientTests.swift — plan §6 Slice A.
//
import Testing
@testable import AriKit

struct StubLLMClientTests {
    @Test func generateReturnsCannedResponse() async throws {
        let client = StubLLMClient(kind: .openAI, cannedResponse: "hello world")
        let result = try await client.generate(LLMRequest(system: "s", user: "u"))
        #expect(result == "hello world")
        #expect(client.kind == .openAI)
    }

    @Test func generateThrowsInjectedError() async {
        let client = StubLLMClient(kind: .claude, error: .requestFailed("boom"))
        await #expect(throws: LLMError.self) {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
        }
    }

    @Test func streamYieldsCannedDeltasInOrderThenFinishes() async throws {
        let client = StubLLMClient(cannedDeltas: ["one", "two", "three"])
        var collected: [String] = []
        for try await delta in client.stream(LLMRequest(system: "s", user: "u")) {
            collected.append(delta)
        }
        #expect(collected == ["one", "two", "three"])
    }

    @Test func streamFinishesWithInjectedError() async {
        let client = StubLLMClient(error: .cancelled)
        var caught: Error?
        do {
            for try await _ in client.stream(LLMRequest(system: "s", user: "u")) {}
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test func defaultStreamFallbackYieldsFullGenerateOnce() async throws {
        // A conformer that does NOT override `stream` (only relies on the protocol default)
        // should emit the full `generate` result exactly once, then finish — this exercises the
        // `LLMClient` extension in LLMClient.swift, not StubLLMClient's own override.
        struct NonStreamingClient: LLMClient {
            let kind: ProviderKind = .claudeCLI
            func generate(_ request: LLMRequest) async throws -> String {
                "full answer"
            }
        }
        let client = NonStreamingClient()
        var collected: [String] = []
        for try await delta in client.stream(LLMRequest(system: "s", user: "u")) {
            collected.append(delta)
        }
        #expect(collected == ["full answer"])
    }
}
