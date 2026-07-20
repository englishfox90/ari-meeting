//
//  CMTimeMappingTests.swift — plan §6 Slice A (← Entry.swift:97-100,199-214).
//
//  `extractWordTimingsAndMeanConfidence...` hand-synthesizes an `AttributedString` carrying
//  `.audioTimeRange`/`.transcriptionConfidence` runs — exactly how `FoundationModelsClientTests`
//  builds inputs without a live session — so this runs headlessly, with no live transcription.
//
import CoreMedia
import Foundation
import Speech
import Testing
@testable import AriKit

struct CMTimeMappingTests {

    // MARK: - seconds(_:)

    @Test func invalidTimeMapsToZero() {
        #expect(CMTimeMapping.seconds(CMTime.invalid) == 0)
    }

    @Test func indefiniteTimeMapsToZero() {
        #expect(CMTimeMapping.seconds(CMTime.indefinite) == 0)
    }

    @Test func validTimeMapsToCorrectSeconds() {
        let time = CMTime(seconds: 12.5, preferredTimescale: 600)
        #expect(abs(CMTimeMapping.seconds(time) - 12.5) < 0.0001)
    }

    @Test func zeroTimeMapsToZero() {
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        #expect(CMTimeMapping.seconds(time) == 0)
    }

    // MARK: - extractWordTimings(from:) — hand-synthesized AttributedString runs

    private func run(_ text: String, start: Double, end: Double, confidence: Double) -> AttributedString {
        var container = AttributeContainer()
        container[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        container[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = confidence
        return AttributedString(text, attributes: container)
    }

    @Test func extractsWordTimingsAndMeanConfidenceFromSynthesizedRuns() {
        let combined = run("hello", start: 0, end: 0.5, confidence: 0.9)
            + AttributedString(" ")
            + run("world", start: 0.5, end: 1.0, confidence: 0.7)

        let (words, meanConfidence) = CMTimeMapping.extractWordTimings(from: combined)

        // The plain " " run has no audio time range, so it contributes no WordTiming.
        #expect(words.count == 2)
        #expect(words[0].text == "hello")
        #expect(abs(words[0].startSec - 0) < 0.0001)
        #expect(abs(words[0].endSec - 0.5) < 0.0001)
        #expect(words[0].confidence == 0.9)
        #expect(words[1].text == "world")
        #expect(abs(words[1].startSec - 0.5) < 0.0001)
        #expect(abs(words[1].endSec - 1.0) < 0.0001)
        #expect(words[1].confidence == 0.7)
        #expect(abs((meanConfidence ?? -1) - 0.8) < 0.0001)
    }

    @Test func runWithoutAudioTimeRangeIsSkippedForWordTimingButStillContributesConfidence() {
        var confidenceOnly = AttributeContainer()
        confidenceOnly[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = 0.5
        let noRangeRun = AttributedString("filler", attributes: confidenceOnly)

        let (words, meanConfidence) = CMTimeMapping.extractWordTimings(from: noRangeRun)

        #expect(words.isEmpty)
        #expect(meanConfidence == 0.5)
    }

    @Test func plainTextWithNoAttributesYieldsNoWordsAndNilConfidence() {
        let plain = AttributedString("plain text, no speech attributes")

        let (words, meanConfidence) = CMTimeMapping.extractWordTimings(from: plain)

        #expect(words.isEmpty)
        #expect(meanConfidence == nil)
    }
}
