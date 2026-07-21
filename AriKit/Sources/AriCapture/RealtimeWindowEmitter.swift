//
//  RealtimeWindowEmitter.swift — bridges a realtime audio callback (AVAudioEngine tap block,
//  CoreAudio IOProc block) into a non-blocking `AsyncStream<PCMWindow>` publish, shared by
//  `MicrophoneCapture` (R3) and `SystemAudioTap` (R4) (docs/plans/ari-recording-page.md §3:
//  "callbacks → ring → coordinator loop", the `pipeline.rs:887-895` `recording_sender` fork
//  discipline applied one layer earlier, at the device boundary).
//
//  Resamples to 48 kHz mono on the callback thread (pure `AVAudioConverter` computation — no
//  locks, no I/O, no `await`) and yields into a `.bufferingNewest` continuation, whose `yield`
//  is synchronous and never blocks the realtime thread (arikit-native-shell.md §3 "Sendable
//  boundaries" / swift-conventions.md Q2 hot-path rule).
//
#if os(macOS)
    import AriKit
    import Foundation

    /// `@unchecked Sendable`, justified: both call sites that mutate this type's state
    /// (`AVAudioEngine`'s tap block and CoreAudio's `AudioDeviceIOProcID` block) are guaranteed
    /// by their respective frameworks to invoke their callback **strictly serially, never
    /// concurrently, on a single realtime audio thread** — AVFoundation and CoreAudio both
    /// document this as the whole point of the realtime-safety contract those callbacks operate
    /// under. So `windowID` here is touched by exactly one thread at a time in practice; there is
    /// no actual data race for the compiler to guard against, only the same class of false-
    /// positive `Sendable` diagnostic already documented for `Resampler`'s conversion callback
    /// (`Resampler.swift`). Using an actor here is not an option: actor isolation requires
    /// `await`, and the entire point of this type is to be callable synchronously from a thread
    /// that must never await.
    final class RealtimeWindowEmitter: @unchecked Sendable {
        let source: CaptureSource
        private let continuation: AsyncStream<PCMWindow>.Continuation
        private let resampler = Resampler()
        private let startDate = Date()
        private var windowID: UInt64 = 0

        init(source: CaptureSource, continuation: AsyncStream<PCMWindow>.Continuation) {
            self.source = source
            self.continuation = continuation
        }

        /// Resample `samples` (from `sourceSampleRate`) to 48 kHz mono and publish as one
        /// `PCMWindow`. Honest no-op on empty/all-dropped input — never fabricates a window
        /// (No-Fake-State); a resample failure is treated the same way (an honest silent drop,
        /// never invented audio), never propagated as a crash from a realtime callback.
        func emit(samples: [Float], sourceSampleRate: Double) {
            guard !samples.isEmpty else { return }
            guard let resampled = try? resampler.resample(samples, from: sourceSampleRate),
                  !resampled.isEmpty
            else {
                return
            }

            let hostTime = Date().timeIntervalSince(startDate)
            let window = PCMWindow(
                samples: resampled,
                sampleRate: Resampler.targetSampleRate,
                source: source,
                hostTime: hostTime,
                windowID: windowID
            )
            windowID += 1
            continuation.yield(window)
        }

        func finish() {
            continuation.finish()
        }
    }
#endif
