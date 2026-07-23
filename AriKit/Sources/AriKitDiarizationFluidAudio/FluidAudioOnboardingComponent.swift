//
//  FluidAudioOnboardingComponent.swift — `FluidAudioDiarizationProvider`'s conformance to
//  `OnboardingInstallableComponent` (docs/plans/onboarding-install-flow.md §2.2). Kept in its own
//  file (rather than inline in `FluidAudioDiarizationProvider.swift`) so the diarization-runtime
//  file stays focused on `DiarizationProvider` itself.
//
#if os(macOS)
    import AriKit
    import FluidAudio
    import Foundation

    extension FluidAudioDiarizationProvider: OnboardingInstallableComponent {
        public nonisolated var componentID: OnboardingComponentID {
            .diarization
        }

        public nonisolated var displayName: String {
            "Speaker identification"
        }

        /// FluidAudio does NOT expose a public "already downloaded" check for
        /// `OfflineDiarizerModels` (`ModelCache.allModelsExist`/`missingModels` are internal to
        /// the FluidAudio module) — so this is a best-effort `FileManager.fileExists` check on
        /// the same repo directory `purgeDiarizerModelsCache()` already constructs. A hint, never
        /// a guarantee: a partial/corrupt download would hint `true` and `ensureReady` would
        /// still do the real work and self-heal via the existing purge-and-retry-once path.
        public nonisolated func quickPresenceHint() async -> Bool {
            Self.presenceHint(modelsDirectory: OfflineDiarizerModels.defaultModelsDirectory())
        }

        /// Pure, testable core of `quickPresenceHint()` (test 8, docs/plans/
        /// onboarding-install-flow.md §7): non-empty repo directory ⇒ `true`. Extracted so a test
        /// can pin the honesty boundary against a filesystem FIXTURE (a real temp directory)
        /// rather than the real machine's actual cache state.
        static func presenceHint(modelsDirectory: URL) -> Bool {
            let repoDirectory = modelsDirectory
                .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            let contents = try? FileManager.default.contentsOfDirectory(atPath: repoDirectory.path)
            return !(contents?.isEmpty ?? true)
        }

        /// Calls `OfflineDiarizerModels.load` directly (not through the narrower
        /// `DiarizationProvider.prepare(progress:)` `Double`-only signature) so the FULL
        /// `DownloadProgress`/`DownloadPhase` detail is available to map onto
        /// `OnboardingInstallProgress` honestly — `.listing`/`.compiling` become indeterminate
        /// phases (no fabricated fraction), `.downloading` reports the real fraction FluidAudio
        /// computed from `completedFiles`/`totalFiles`.
        public func ensureReady(
            progress: (@Sendable (OnboardingInstallProgress) -> Void)?
        ) async throws {
            progress?(.checking)
            do {
                _ = try await preparedModels { downloadProgress in
                    progress?(Self.mapDownloadProgress(downloadProgress))
                }
            } catch let error as DiarizationError {
                throw error
            } catch {
                throw DiarizationError.modelsUnavailable(String(describing: error))
            }
        }

        static func mapDownloadProgress(_ downloadProgress: DownloadProgress) -> OnboardingInstallProgress {
            switch downloadProgress.phase {
            case .listing:
                .indeterminate(phase: "Checking for updates…")
            case .downloading:
                .downloading(fractionCompleted: downloadProgress.fractionCompleted)
            case .compiling:
                .compiling
            }
        }
    }
#endif
