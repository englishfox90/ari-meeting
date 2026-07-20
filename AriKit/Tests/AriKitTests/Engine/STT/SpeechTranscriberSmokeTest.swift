//
//  SpeechTranscriberSmokeTest.swift — plan §6 Slice C, Lane 2 (asset-gated, honest-SKIP).
//
//  Exercises the REAL `SpeechTranscriberProvider.transcribe(fileURL:language:)` recorded-file path
//  against an OPTIONAL, uncommitted real-speech WAV file — never a committed fixture (plan §11.3
//  privacy ruling: subagents commit NO audio). Runs ONLY when BOTH:
//    1. `SpeechAssetManager().areAssetsInstalled(forLocale:)` reports the target locale's model
//       assets are already installed on this machine, AND
//    2. the env var `ARIKIT_STT_SMOKE_WAV` points at an existing, readable audio file.
//
//  Otherwise this records an honest SKIP (print + early return) rather than fabricating a pass —
//  mirrors `SpeechAssetManagerTests`'s Lane-2 skip discipline exactly (No-Fake-State, plan §7/§11.3).
//
import Foundation
import Testing
@testable import AriKit

private let smokeWAVEnvVar = "ARIKIT_STT_SMOKE_WAV"
private let smokeLocale = "en-US"

struct SpeechTranscriberSmokeTest {
    @Test func transcribesARealUncommittedWAVFileWhenAvailable() async throws {
        let assetManager = SpeechAssetManager()

        guard assetManager.isEngineAvailable() else {
            print(
                "SKIP: transcribesARealUncommittedWAVFileWhenAvailable — SpeechTranscriber.isAvailable is false on this machine."
            )
            return
        }
        guard await assetManager.areAssetsInstalled(forLocale: smokeLocale) else {
            print(
                "SKIP: transcribesARealUncommittedWAVFileWhenAvailable — \(smokeLocale) speech model assets are not installed on this machine."
            )
            return
        }
        guard let path = ProcessInfo.processInfo.environment[smokeWAVEnvVar], !path.isEmpty else {
            print(
                "SKIP: transcribesARealUncommittedWAVFileWhenAvailable — set \(smokeWAVEnvVar) to an uncommitted, local real-speech WAV file to exercise this test; no audio is committed to the repo."
            )
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print(
                "SKIP: transcribesARealUncommittedWAVFileWhenAvailable — \(smokeWAVEnvVar)=\(path) does not exist."
            )
            return
        }

        let provider = SpeechTranscriberProvider()
        let result = try await provider.transcribe(fileURL: fileURL, language: smokeLocale)

        #expect(!result.segments.isEmpty, "expected at least one finalized segment from real speech audio")
        #expect(
            !result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "expected non-empty transcribed text from real speech audio"
        )
        #expect(result.wordTimestampCount > 0, "expected real per-word timestamps from SpeechTranscriber")

        guard let audioDurationSec = result.audioDurationSec else {
            Issue.record("expected a real audio duration from AVAudioFile, never nil for a valid file")
            return
        }

        for segment in result.segments {
            #expect(segment.startSec >= 0)
            #expect(segment.startSec < segment.endSec)
            #expect(segment.endSec <= audioDurationSec + 0.5) // small tolerance for rounding
        }
    }
}
