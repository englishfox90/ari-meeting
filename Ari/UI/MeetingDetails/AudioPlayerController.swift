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

    private var player: AVPlayer?
    private var timeObserverToken: Any?

    /// Loads a new audio file, replacing any currently-loaded player.
    func load(url: URL) {
        teardown()
        let player = AVPlayer(url: url)
        self.player = player
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // The observer fires on `.main`, i.e. the MainActor's executor, so touching
            // main-actor state here is safe — assert that explicitly rather than shipping the
            // strict-concurrency warning (swift-conventions: resolve isolation warnings).
            MainActor.assumeIsolated {
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
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func teardown() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
    }
}
