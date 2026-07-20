//
//  StubTranscriptionProviderTests.swift — plan §6 Slice A (mirrors `StubLLMClientTests`).
//
import Foundation
import Speech
import Testing
@testable import AriKit

struct StubTranscriptionProviderTests {
    @Test func isAvailableReflectsInjectedAvailability() async {
        let available = StubTranscriptionProvider(available: true)
        #expect(await available.isAvailable() == true)

        let unavailable = StubTranscriptionProvider(available: false)
        #expect(await unavailable.isAvailable() == false)
    }

    @Test func currentModelReturnsInjectedModel() async {
        let provider = StubTranscriptionProvider(model: "en-US-v1")
        #expect(await provider.currentModel() == "en-US-v1")
    }

    @Test func transcribeFileReturnsCannedSegmentsAndDerivedResult() async throws {
        let segments = [
            TranscriptionSegment(text: "hello", startSec: 0, endSec: 1, confidence: 0.9, words: []),
            TranscriptionSegment(text: "world", startSec: 1, endSec: 2, confidence: 0.8, words: [])
        ]
        let provider = StubTranscriptionProvider(cannedSegments: segments)

        let result = try await provider.transcribe(fileURL: URL(fileURLWithPath: "/dev/null"), language: "en-US")

        #expect(result.segments == segments)
        #expect(result.fullText == "hello world")
        #expect(result.audioDurationSec == 2)
        #expect(result.wordTimestampCount == 0)
    }

    @Test func transcribeFileThrowsInjectedError() async {
        let provider = StubTranscriptionProvider(error: .providerUnavailable("no assets"))

        await #expect(throws: TranscriptionError.self) {
            _ = try await provider.transcribe(fileURL: URL(fileURLWithPath: "/dev/null"), language: nil)
        }
    }

    @Test func liveTranscribeYieldsCannedSegmentsInOrderThenFinishes() async throws {
        let segments = [
            TranscriptionSegment(text: "one", startSec: 0, endSec: 1, confidence: nil, words: []),
            TranscriptionSegment(text: "two", startSec: 1, endSec: 2, confidence: nil, words: [])
        ]
        let provider = StubTranscriptionProvider(cannedSegments: segments)
        let (inputSequence, _) = AsyncStream<AnalyzerInput>.makeStream()

        var collected: [TranscriptionSegment] = []
        for try await segment in provider.transcribe(liveInputs: inputSequence, language: nil) {
            collected.append(segment)
        }

        #expect(collected == segments)
    }

    @Test func liveTranscribeFinishesWithInjectedError() async {
        let provider = StubTranscriptionProvider(error: .engineFailed("boom"))
        let (inputSequence, _) = AsyncStream<AnalyzerInput>.makeStream()

        var caught: Error?
        do {
            for try await _ in provider.transcribe(liveInputs: inputSequence, language: nil) {}
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }
}
