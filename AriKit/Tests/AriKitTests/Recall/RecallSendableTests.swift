//
//  RecallSendableTests.swift — plan §6 Slice 1 test 9.
//
//  Compile-time `Sendable` guarantee for every public recall type (plan §3): if any type loses
//  `Sendable`, `requireSendable(_:)` fails to compile. Mirrors `SendableInventoryTests`.
//
import Testing
@testable import AriKit

@Suite struct RecallSendableTests {
    private func requireSendable(_: (some Sendable).Type) {}

    @Test func everyRecallTypeIsSendable() {
        requireSendable(RecallSource.self)
        requireSendable(RecallResponse.self)
        requireSendable(RecallTurn.self)
        requireSendable(TranscriptSearchResult.self)
        requireSendable(ChunkDraft.self)
        requireSendable(EmbedBackend.self)
        requireSendable(RecallError.self)

        #expect(Bool(true))
    }
}
