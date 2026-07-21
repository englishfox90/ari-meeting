//
//  PCMWindow.swift — the capture ↔ STT/diarization seam type (arikit-native-shell.md §2.3,
//  ← `frontend/src-tauri/src/audio/recording_state.rs` `AudioChunk`).
//
//  One window of captured PCM at the fork point inside the (not-yet-built) `CaptureCoordinator`
//  (Phase 3.2, slice S4) — the Swift analog of `AudioPipeline::run()`
//  (`audio/pipeline.rs:824-878`). 48 kHz mono f32, mic and system still SEPARATE at this point:
//  this is the Q2 seam (`.claude/context/open-questions.md`) — forked non-blocking BEFORE
//  mixing, so both the mixed-STT path and later diarization (F1, Phase 3.5) can consume the
//  pre-mix streams from the same contract.
//
//  Lives in `AriKit` (not `AriCapture`) so both `AriCapture` (produces `PCMWindow`) and
//  `AriKit.Engine` (consumes it for STT, Phase 3.3) see the type without either target
//  depending on the other (plan §2.2/§5, capture→STT adapter ownership).
//
//  `Sendable` value type: crosses the non-blocking fork / `AsyncStream` continuations to STT
//  and (later) diarization consumers without any shared mutable state.
//

/// One window of captured PCM (← `AudioChunk`, `recording_state.rs:17-25`).
public struct PCMWindow: Sendable, Equatable {
    /// Mono PCM samples, normalized to `[-1, 1]` (← `AudioChunk.data: Vec<f32>`). An empty
    /// array is a valid, honest representation of "no audio this window" (No-Fake-State) —
    /// never a fabricated stand-in for a dropped or short read.
    public var samples: [Float]

    /// Sample rate of `samples`, in Hz. `48_000` at the fork point in the coordinator: mic is
    /// already resampled up from its native hardware rate (← `Resampler`), system audio is
    /// 48 kHz passthrough (← `AudioChunk.sample_rate`, always 48 kHz at this seam in the
    /// incumbent).
    public var sampleRate: Double

    /// Which capture path produced this window (← `DeviceType`, `recording_state.rs:12-15`).
    public var source: CaptureSource

    /// Seconds from recording start (← `AudioChunk.timestamp`). This is the "timing is free"
    /// property noted in `open-questions.md` Q4: the VAD segment PCM == the STT PCM == the
    /// transcript's time range, so no separate alignment step is needed downstream.
    public var hostTime: Double

    /// Monotonic per-window identifier, unique within one recording (← `AudioChunk.chunk_id`).
    public var windowID: UInt64

    public init(
        samples: [Float],
        sampleRate: Double,
        source: CaptureSource,
        hostTime: Double,
        windowID: UInt64
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.source = source
        self.hostTime = hostTime
        self.windowID = windowID
    }
}

/// Which capture path produced a `PCMWindow` (← Rust `DeviceType`, `recording_state.rs:12-15`).
///
/// `.mixed` has no direct Rust `AudioChunk`-level analog: the incumbent's mixer collapses
/// mic+system into one stream immediately before VAD/STT (`pipeline.rs:878`) without ever
/// re-tagging the result as an `AudioChunk`. Swift's `AudioMixer` output needs a source label
/// too (it is itself a `PCMWindow` once mixed), so `.mixed` is added here.
public enum CaptureSource: Sendable, Equatable, CaseIterable {
    case microphone
    case system
    case mixed
}
