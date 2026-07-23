//
//  FluidAudioOnboardingComponentTests.swift — acceptance tests 5 (partial) + 8 (docs/plans/
//  onboarding-install-flow.md §7). Pure, no network:
//    - `mapDownloadProgress` maps known `DownloadProgress` fixtures to the expected
//      `OnboardingInstallProgress` cases (test 5).
//    - `quickPresenceHint()` is a filesystem-only hint — `false` against an empty temp
//      directory, `true` against a directory pre-seeded with the expected repo folder-name
//      structure (test 8) — pins the honesty boundary: never claims more than "a directory
//      with this name exists".
//
#if os(macOS)
    import AriKit
    import FluidAudio
    import Foundation
    import Testing
    @testable import AriKitDiarizationFluidAudio

    @Suite("FluidAudioOnboardingComponent")
    struct FluidAudioOnboardingComponentTests {
        @Test("componentID and displayName are stable, provider-facing identifiers")
        func componentIdentity() {
            let provider = FluidAudioDiarizationProvider()
            #expect(provider.componentID == .diarization)
            #expect(provider.displayName == "Speaker identification")
        }

        @Test("mapDownloadProgress: .listing becomes an indeterminate phase, never a fabricated fraction")
        func mapsListingToIndeterminate() {
            let progress = DownloadProgress(fractionCompleted: 0.0, phase: .listing)
            let mapped = FluidAudioDiarizationProvider.mapDownloadProgress(progress)
            guard case .indeterminate = mapped else {
                Issue.record("expected .indeterminate for .listing, got \(mapped)")
                return
            }
        }

        @Test("mapDownloadProgress: .downloading forwards the REAL fraction FluidAudio computed")
        func mapsDownloadingToRealFraction() {
            let progress = DownloadProgress(
                fractionCompleted: 0.42,
                phase: .downloading(completedFiles: 2, totalFiles: 5)
            )
            let mapped = FluidAudioDiarizationProvider.mapDownloadProgress(progress)
            #expect(mapped == .downloading(fractionCompleted: 0.42))
        }

        @Test("mapDownloadProgress: .compiling becomes .compiling, no fabricated fraction")
        func mapsCompilingToCompiling() {
            let progress = DownloadProgress(fractionCompleted: 1.0, phase: .compiling(modelName: "segmentation"))
            let mapped = FluidAudioDiarizationProvider.mapDownloadProgress(progress)
            #expect(mapped == .compiling)
        }

        @Test("presenceHint is false against an empty temp directory (no repo subdirectory at all)")
        func presenceHintFalseAgainstEmptyDirectory() throws {
            let tempDir = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            #expect(FluidAudioDiarizationProvider.presenceHint(modelsDirectory: tempDir) == false)
        }

        @Test("presenceHint is true against a directory pre-seeded with the expected repo folder-name structure")
        func presenceHintTrueAgainstSeededFixture() throws {
            let tempDir = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repoDirectory = tempDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
            try Data("placeholder".utf8).write(to: repoDirectory.appendingPathComponent("segmentation.mlmodelc"))

            #expect(FluidAudioDiarizationProvider.presenceHint(modelsDirectory: tempDir) == true)
        }

        @Test(
            "presenceHint is false against an EMPTY repo directory (never claims more than 'a non-empty directory exists')"
        )
        func presenceHintFalseAgainstEmptyRepoDirectory() throws {
            let tempDir = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repoDirectory = tempDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)

            #expect(FluidAudioDiarizationProvider.presenceHint(modelsDirectory: tempDir) == false)
        }

        private static func makeTempDirectory() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidAudioOnboardingComponentTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }
#endif
