//! Live recording audio level — a lock-free hand-off from the audio pipeline's
//! hot mixing loop to any consumer that wants an instantaneous meter.
//!
//! Today the sole consumer is the notch HUD: `AudioPipeline::run()` PUBLISHES the
//! latest mixed-window level (0.0–1.0) each ~600 ms window, and the notch bridge
//! SAMPLES it at ~10 Hz to push `AudioLevel` down to the sidecar (see
//! `crate::notch::bridge`). Deliberately NOT the `audio-levels` Tauri event path
//! (that one is driven by `simple_level_monitor`, which emits fake sine-wave data
//! for the device-selection preview and is stopped during recording).
//!
//! Stored as the raw f32 bit pattern in a single `AtomicU32`, so both publish and
//! read are a lone relaxed atomic op — they never lock and never block the audio
//! loop. There is exactly one producer (the pipeline task) and one consumer (the
//! notch meter task); a torn read is impossible on a 32-bit aligned atomic, and
//! staleness of a few milliseconds is irrelevant for a visual meter.

use std::sync::atomic::{AtomicU32, Ordering};

/// Latest published level as f32 bits. `0` == `0.0` (silence) before anything is
/// ever published.
static LEVEL_BITS: AtomicU32 = AtomicU32::new(0);

/// Publish the latest instantaneous level, clamped to 0.0–1.0. Called from the
/// audio pipeline's hot loop — MUST stay lock-free / non-blocking.
pub fn publish(level: f32) {
    LEVEL_BITS.store(level.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
}

/// The most recently published level (0.0–1.0). Returns `0.0` when nothing has
/// been published yet or after `reset()`.
pub fn current() -> f32 {
    f32::from_bits(LEVEL_BITS.load(Ordering::Relaxed))
}

/// Reset to silence. Called when recording stops so a stale level from the last
/// session can't linger into the next one.
pub fn reset() {
    LEVEL_BITS.store(0, Ordering::Relaxed); // 0 bits == 0.0f32
}
