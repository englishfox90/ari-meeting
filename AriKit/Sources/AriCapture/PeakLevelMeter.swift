//
//  PeakLevelMeter.swift — instantaneous 0...1 audio level for the live meter (notch HUD +
//  the recording page), ported verbatim from the Rust live-meter calc it replaces
//  (`frontend/src-tauri/src/audio/pipeline.rs:800-818`, `crate::audio::live_level`).
//
//  Pure value semantics, no I/O (mirrors `AudioMixer` — Lane 1, headless-testable).
//

/// Turns one mixed window's raw peak amplitude into a level that actually tracks speech on
/// screen. Two corrections the raw peak alone is missing:
///
/// - **Gain (x1.3):** the mic is EBU R128 loudness-normalized to ~-23 LUFS, which keeps its
///   raw peak well below full scale even for normal speech. The Rust original found x1.3
///   "fills the meter for normal speech without pinning at 1.0" — carried over verbatim.
/// - **Peak-hold decay:** windows alternate mic (usually loud) and system (often silent), and
///   a per-window instantaneous peak would flicker toward zero on every quiet window. Holding
///   the peak and decaying it ~15% per window (instead of snapping to the new instantaneous
///   value) gives an immediate attack on a louder peak but a gradual release — smooth motion
///   instead of a flickering, near-frozen meter.
public struct PeakLevelMeter: Sendable {
    private var held: Float = 0

    public init() {}

    /// Feed one window's samples (already mixed, mono float, nominally `[-1, 1]`); returns the
    /// level to publish (0...1). Empty input leaves — and returns — the currently held level
    /// unchanged (no data to attack OR decay on).
    public mutating func update(with samples: [Float]) -> Float {
        guard !samples.isEmpty else { return held }
        let peak = samples.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
        let instant = min(peak * 1.3, 1.0)
        held = max(instant, held * 0.85)
        return held
    }
}
