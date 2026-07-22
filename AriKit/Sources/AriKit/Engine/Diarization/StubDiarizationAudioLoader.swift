//
//  StubDiarizationAudioLoader.swift — deterministic `DiarizationAudioLoading` test double (plan
//  §2.7, D8; mirrors `StubDiarizationProvider.swift`).
//
//  `#if DEBUG`-only: this must never be reachable from a shipped (release) build. `DiarizationService`
//  tests run against this rather than `AriCapture.DiarizationAudioLoader`'s real AVFoundation decode.
//
#if DEBUG
    import Foundation

    public struct StubDiarizationAudioLoader: DiarizationAudioLoading {
        public var samples: [Float]
        public var error: DiarizationError?

        public init(samples: [Float] = [0.0, 0.0], error: DiarizationError? = nil) {
            self.samples = samples
            self.error = error
        }

        public func load16kMono(from _: URL) async throws -> [Float] {
            if let error {
                throw error
            }
            return samples
        }
    }
#endif
