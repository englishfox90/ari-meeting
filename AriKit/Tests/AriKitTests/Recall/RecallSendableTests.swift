//
//  RecallSendableTests.swift — plan §6 Slice 1 test 9.
//
//  Compile-time `Sendable` guarantee for every public recall type (plan §3): if any type loses
//  `Sendable`, `requireSendable(_:)` fails to compile. Mirrors `SendableInventoryTests`.
//
import Testing
@testable import AriKit

struct RecallSendableTests {
    private func requireSendable(_: (some Sendable).Type) {}

    @Test func everyRecallTypeIsSendable() {
        requireSendable(RecallSource.self)
        requireSendable(RecallResponse.self)
        requireSendable(RecallTurn.self)
        requireSendable(TranscriptSearchResult.self)
        requireSendable(ChunkDraft.self)
        requireSendable(EmbedBackend.self)
        requireSendable(RecallError.self)

        // Recall Slice 2 (docs/plans/arikit-recall-slice2.md §6, "extend SendableInventoryTests")
        requireSendable(RecallChunkID.self)
        requireSendable(RecallChunk.self)
        requireSendable(RecallChunkInput.self)
        requireSendable(RecallIndexState.self)
        requireSendable(RecallIndexSummary.self)
        requireSendable(RecallFTSHit.self)
        requireSendable(RecallEmbeddingRow.self)
        requireSendable(RecallIndexRepository.self)

        // Recall Slice 8 (docs/plans/arikit-recall.md §6, "extend SendableInventoryTests")
        requireSendable(RecallEngine.self)
        requireSendable(RecallEngineError.self)
        requireSendable(RecallModelConfig.self)
        requireSendable(RecallStreamEvent.self)

        #expect(Bool(true))
    }
}
