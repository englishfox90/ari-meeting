//
//  ProviderSendableInventoryTests.swift — plan §6 Slice A.
//
//  Every public type in the Slice A provider surface must be `Sendable` — this is enforced at
//  COMPILE TIME (a non-Sendable type passed to `assertSendable` fails `swift build`/`swift test`,
//  not a runtime assertion). The test bodies are trivial; the value is the generic constraint.
//
//  (Named distinctly from the top-level `SendableInventoryTests` — the domain-model inventory —
//  to avoid a same-basename/same-type-name collision in the single `AriKitTests` module.)
//
import Testing
@testable import AriKit

private func assertSendable(_: some Sendable) {}
private func assertSendableType(_: (some Sendable).Type) {}

struct ProviderSendableInventoryTests {
    @Test func providerValueTypesAreSendable() {
        assertSendableType(LLMRequest.self)
        assertSendableType(ProviderKind.self)
        assertSendableType(ProviderConfig.self)
        assertSendableType(LLMError.self)
        assertSendableType(ProviderFactory.MLXClientProvider.self)
    }

    @Test func anyLLMClientExistentialIsSendable() {
        // `LLMClient: Sendable` means every existential value is usable as `any Sendable` —
        // this only compiles if the protocol conformance requirement actually holds.
        let client: any LLMClient = StubLLMClient()
        assertSendable(client)
    }

    @Test func stubClientIsSendable() {
        assertSendableType(StubLLMClient.self)
    }
}
