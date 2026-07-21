//
//  AnalyzerInputAdapter.swift — the capture ↔ STT join adapter (plan §2.2, ari-recording-page.md;
//  shell §9-4: this adapter is Engine-side, not `AriCapture`-side, so `AriCapture` never imports
//  `Speech`).
//
//  `PCMWindow` (48 kHz mono f32, `AriKit/Sources/AriKit/Capture/PCMWindow.swift`) → an
//  `AVAudioPCMBuffer` at that same native format → `AnalyzerInput(buffer:)`, exposed as a lazy
//  mapped `AsyncSequence` so a slow STT consumer never forces the capture side to buffer/block —
//  windows are converted to buffers only as the consumer actually pulls them (`compactMap`'s
//  standard-library laziness).
//
//  Empty windows (`PCMWindow.samples.isEmpty`, a real, honest "no audio this window" outcome —
//  never a fabricated dropped-window stand-in, see `PCMWindow`'s own doc comment) are skipped
//  entirely: no zero-length/fabricated buffer is ever handed to the analyzer.
//
//  Format-conversion note: this adapter emits buffers at the window's own native format
//  (48 kHz mono Float32) VERBATIM — the negotiation to the analyzer's preferred format happens
//  one layer downstream, inside `SpeechTranscriberProvider.transcribe(liveInputs:language:)`
//  (`convertLiveBuffer`, via `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`), because
//  it needs the live `SpeechTranscriber` instance this signature deliberately doesn't carry.
//  That conversion is MANDATORY, not cosmetic: feeding SpeechAnalyzer's live input a format it
//  didn't agree to traps inside the Speech framework (SIGTRAP in
//  `SpeechRecognizerWorker.processAudio` — found in Lane 2, 2026-07-21). Only the file path may
//  skip a manual convert, since `analyzeSequence(from: AVAudioFile)` negotiates internally.
//
import AVFoundation
import Foundation
import Speech

public enum AnalyzerInputAdapter {
    /// Maps a stream of captured PCM windows to `AnalyzerInput`s, lazily and non-blocking.
    ///
    /// - Empty windows (`samples.isEmpty`) are skipped (honest gap == silence, never a fabricated
    ///   buffer).
    /// - A window whose buffer fails to construct (format/allocation failure — should not happen
    ///   for well-formed `PCMWindow`s, but is not treated as fatal here) is also skipped rather
    ///   than crashing the whole live session; this mirrors "a dropped window is silence, never
    ///   invented audio" (§3).
    public static func analyzerInputs(
        from windows: AsyncStream<PCMWindow>
    ) -> some AsyncSequence<AnalyzerInput, Never> & Sendable {
        windows.compactMap { window -> AnalyzerInput? in
            guard !window.samples.isEmpty else { return nil }
            guard let buffer = try? Self.buffer(from: window) else { return nil }
            return AnalyzerInput(buffer: buffer)
        }
    }

    /// The pure PCMWindow → AVAudioPCMBuffer conversion layer, factored out so it is directly
    /// unit-testable without needing to construct/inspect an opaque `AnalyzerInput`
    /// (`AnalyzerInputAdapterTests`, ari-recording-page.md §6).
    static func buffer(from window: PCMWindow) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: window.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AnalyzerInputAdapterError.formatConstructionFailed(sampleRate: window.sampleRate)
        }
        let frameCount = AVAudioFrameCount(window.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData else {
            throw AnalyzerInputAdapterError.bufferAllocationFailed(frameCount: window.samples.count)
        }
        buffer.frameLength = frameCount
        window.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: window.samples.count)
        }
        return buffer
    }
}

/// Honest failure reasons for `AnalyzerInputAdapter.buffer(from:)` — never a silently-empty buffer.
enum AnalyzerInputAdapterError: Error, Sendable, Equatable {
    case formatConstructionFailed(sampleRate: Double)
    case bufferAllocationFailed(frameCount: Int)
}
