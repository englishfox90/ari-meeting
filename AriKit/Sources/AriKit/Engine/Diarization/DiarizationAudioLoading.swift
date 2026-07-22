//
//  DiarizationAudioLoading.swift — the audio-decode seam for diarization (plan §2.7).
//
//  Introduced in D6, ahead of D8's `DiarizationService.swift` (where the plan's §2.7 code block
//  shows this protocol declared): `AriCapture.DiarizationAudioLoader` (D6) needs a protocol to
//  conform to, and `AriCapture` depends on `AriKit`, never the reverse — so the seam has to live
//  here first. Zero-dependency leaf protocol; D8 consumes it unchanged.
//
import Foundation

/// Decode any AVFoundation-readable meeting file to 16 kHz mono `[-1, 1]` PCM. Implemented by
/// `AriCapture.DiarizationAudioLoader`.
public protocol DiarizationAudioLoading: Sendable {
    func load16kMono(from url: URL) async throws -> [Float]
}
