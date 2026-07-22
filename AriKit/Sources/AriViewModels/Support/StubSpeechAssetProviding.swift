//
//  StubSpeechAssetProviding.swift — deterministic test double for the on-device speech-asset seam
//  (docs/plans/settings-ui.md §6).
//
//  Lets headless `swift test` drive `SettingsViewModel`'s transcription surface without touching
//  the real `Speech.framework` — mirrors `StubSecretsStoring`. Configurable so a test can assert
//  the engine-available, engine-unavailable, installed, and install-progress paths honestly. An
//  `actor` (not a value type) so a successful `install(...)` actually flips the installed state —
//  the VM re-checks the real installed answer after an install rather than trusting a bare `true`.
//
#if DEBUG
    import AriKit
    import Foundation

    public actor StubSpeechAssetProviding: SpeechAssetProviding {
        public let engineAvailable: Bool
        private var installed: Bool

        public init(
            engineAvailable: Bool = true,
            installed: Bool = false
        ) {
            self.engineAvailable = engineAvailable
            self.installed = installed
        }

        public nonisolated func isEngineAvailable() -> Bool {
            engineAvailable
        }

        public func areAssetsInstalled(forLocale _: String?) async -> Bool {
            engineAvailable && installed
        }

        public func install(
            forLocale _: String?,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {
            onProgress(0.0)
            installed = true
            onProgress(1.0)
        }
    }
#endif
