//
//  STTSendableInventoryTests.swift — plan §6 Slice A.
//
//  Every public type in the Slice A STT surface must be `Sendable` — this is enforced at
//  COMPILE TIME (a non-Sendable type passed to `assertSendable`/`assertSendableType` fails
//  `swift build`/`swift test`, not a runtime assertion). The test bodies are trivial; the value
//  is the generic constraint. Mirrors `ProviderSendableInventoryTests.swift`.
//
import Testing
@testable import AriKit

private func assertSendable(_: some Sendable) {}
private func assertSendableType(_: (some Sendable).Type) {}

struct STTSendableInventoryTests {
    @Test func sttValueTypesAreSendable() {
        assertSendableType(TranscriptionResult.self)
        assertSendableType(TranscriptionSegment.self)
        assertSendableType(WordTiming.self)
        assertSendableType(TranscriptionError.self)
    }

    @Test func speechTranscriberProviderIsSendable() {
        assertSendableType(SpeechTranscriberProvider.self)
        let provider: any TranscriptionProvider = SpeechTranscriberProvider()
        assertSendable(provider)
    }

    #if DEBUG
        @Test func anyTranscriptionProviderExistentialIsSendable() {
            // `TranscriptionProvider: Sendable` means every existential value is usable as
            // `any Sendable` — this only compiles if the protocol conformance requirement
            // actually holds.
            let provider: any TranscriptionProvider = StubTranscriptionProvider()
            assertSendable(provider)
        }

        @Test func stubProviderIsSendable() {
            assertSendableType(StubTranscriptionProvider.self)
        }
    #endif
}
