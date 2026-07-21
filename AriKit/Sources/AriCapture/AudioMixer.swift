//
//  AudioMixer.swift — pure 48 kHz mono float mix (arikit-native-shell.md §4.3 step 4,
//  ← `frontend/src-tauri/src/audio/pipeline.rs` `AudioMixerRingBuffer::mix_window`, :154-188).
//
//  Runs AFTER the pre-mix `PCMWindow` fork (the Q2 seam) has already forked the separate
//  mic/system windows to any consumer (STT, later diarization) — this type only produces the
//  single mixed stream that VAD/STT actually transcribes. Pure value semantics, no I/O, no
//  device/AVFoundation dependency: headless-testable (Lane 1, plan §7).
//

/// Mixes separate mic + system PCM windows into one mono window (← `mix_window`,
/// `pipeline.rs:154-188`).
public struct AudioMixer: Sendable {
    public init() {}

    /// Mix `mic` + `system` (both mono float32, same nominal sample rate) into one window.
    ///
    /// - Missing samples in the shorter window are treated as silence (zero), mirroring the
    ///   Rust `.get(i).copied().unwrap_or(0.0)` defensive padding — never a fabricated sample
    ///   (No-Fake-State).
    /// - **No post-gain**: mic is already EBU R128-normalized at capture (~-23 LUFS); system
    ///   audio is summed at its natural level (← `pipeline.rs:880-884`, "previous 2x gain was
    ///   causing excessive limiting/distortion").
    /// - **Soft (proportional) scaling**, not hard clipping: when `|mic + system| > 1.0`, the
    ///   sample is scaled down proportionally to fit `[-1, 1]` rather than clamped, avoiding the
    ///   "radio break" distortion hard-clipping produces (← `pipeline.rs:174-183`).
    /// - Two empty inputs mix to an empty window — honest, not a fabricated block of silence
    ///   samples.
    public func mix(mic: [Float], system: [Float]) -> [Float] {
        let count = max(mic.count, system.count)
        guard count > 0 else { return [] }

        var mixed = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            let micSample = index < mic.count ? mic[index] : 0
            let systemSample = index < system.count ? system[index] : 0
            let sum = micSample + systemSample
            let sumMagnitude = abs(sum)
            mixed[index] = sumMagnitude > 1.0 ? sum / sumMagnitude : sum
        }
        return mixed
    }
}
