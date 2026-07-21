//
//  AudioPlayerController.swift — `@MainActor @Observable` AVPlayer wrapper (plan §5).
//
//  App-target-only (AVFoundation) — `AriViewModels` stays pure of AVFoundation per the
//  swift-conventions split. No byte-range bridge: `AVPlayer(url:)` reads the local file
//  directly (plan §5).
//
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayerController {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    /// Total duration in seconds, `0` until the asset resolves it (never a fabricated total —
    /// the scrubber and duration readout stay inert while it's `0`).
    private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var durationTask: Task<Void, Never>?

    /// Loads a new audio file, replacing any currently-loaded player.
    func load(url: URL) {
        teardown()
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player

        // Duration isn't known synchronously — resolve it off the main actor and publish it
        // back when it arrives. Held so `teardown()` can cancel it: without that, a slow load
        // resolving after the view switched meetings would publish the OLD file's duration onto
        // the current one. A failure/cancel leaves `duration` at 0 (honest: no total shown).
        durationTask = Task { [weak self] in
            guard let resolved = try? await asset.load(.duration) else { return }
            let seconds = resolved.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.duration = seconds }
        }
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // The observer fires on `.main`, i.e. the MainActor's executor, so touching
            // main-actor state here is safe — assert that explicitly rather than shipping the
            // strict-concurrency warning (swift-conventions: resolve isolation warnings).
            MainActor.assumeIsolated {
                // An indefinite/NaN observer time (rare for a local file) must not flow into the
                // scrubber binding or the readout.
                guard time.seconds.isFinite else { return }
                self?.currentTime = time.seconds
            }
        }
    }

    /// Stops playback and fully tears down the player + time observer. Idempotent — safe to call
    /// on `.onDisappear` and when navigating to a meeting whose audio doesn't resolve (so stale
    /// cross-meeting audio can never keep playing with no visible transport to stop it).
    func reset() {
        teardown()
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(toSeconds seconds: Double) {
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        // Reflect the target immediately so a scrubber drag (or a moment-chip tap while paused)
        // tracks without waiting for the periodic observer's next tick.
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    private func teardown() {
        durationTask?.cancel()
        durationTask = nil
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
