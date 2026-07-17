//
//  EnsureAssets.swift
//  apple-helper
//
//  On-device Speech model asset installation for the `ensureAssets` request,
//  factored out of main.swift so it is unit-testable and so the framework calls
//  are isolated.
//
//  Backed by Apple's Speech framework AssetInventory (macOS 26+). This installs
//  the SpeechTranscriber (SpeechAnalyzer) model assets for the user's current
//  locale and reports REAL download progress. Every reported fraction reflects
//  the framework's own `Progress.fractionCompleted` — this function NEVER
//  fabricates progress (No-Fake-State). On ANY failure (Speech unavailable,
//  unsupported `which`, no installation request obtainable, thrown download
//  error, or a post-install verification that still shows the locale missing) it
//  THROWS a descriptive `EnsureAssetsError`; main.swift catches and emits an
//  `AppleResponse.error(message:)` instead of a misleading success.
//
//  Symbols verified against the macOS 26 SDK swiftinterface
//  (Speech.framework, arm64e-apple-macos.swiftinterface):
//    - `SpeechTranscriber.isAvailable: Bool` (static, sync)              [line 399]
//    - `SpeechTranscriber.installedLocales: [Locale]` (static, async)    [line 406]
//    - `SpeechTranscriber.supportedLocale(equivalentTo:) -> Locale?`     [line 405]
//    - `SpeechTranscriber(locale:preset:)` convenience init; the module
//      conforms to `SpeechModule` / `LocaleDependentSpeechModule`        [lines 335-336]
//    - `AssetInventory.assetInstallationRequest(supporting: [any SpeechModule])
//         async throws -> AssetInstallationRequest?`                     [line 36]
//    - `AssetInstallationRequest: ProgressReporting` with
//         `var progress: Foundation.Progress` and
//         `func downloadAndInstall() async throws`                       [lines 494-499]
//
//  PROGRESS GRANULARITY: `AssetInstallationRequest` conforms to
//  `Foundation.ProgressReporting` and exposes a KVO-observable
//  `progress.fractionCompleted`. We observe it and forward each real fraction.
//  Apple does not contractually guarantee how many intermediate fractions the
//  request emits (it may jump straight from 0 to 1 for a small/cached asset), so
//  to guarantee an honest floor we ALSO emit an explicit 0.0 start and, after a
//  verified install, a 1.0 completion. Every value in between is the framework's
//  own number — never interpolated or faked.
//
//  ENTITLEMENTS: on-device SpeechTranscriber asset installation via
//  AssetInventory does NOT require the classic `com.apple.developer.speech-
//  recognition` entitlement — that entitlement (plus `NSSpeechRecognitionUsage
//  Description`) gates the OLDER server-backed `SFSpeechRecognizer` path, not the
//  on-device SpeechAnalyzer/SpeechTranscriber engine introduced in macOS 26. The
//  asset download itself is a system-managed model fetch (like the
//  FoundationModels model download) with no dedicated entitlement key in the
//  SDK. No entitlements file was added. See the task report for the full
//  reasoning and the caveat that this should be confirmed on a machine where the
//  assets are NOT already installed.
//

import Foundation
import Speech

/// A descriptive, honest failure from the ensure-assets path. Its `message` is
/// what the sidecar surfaces to the Rust core as `AppleResponse.error(message:)`.
struct EnsureAssetsError: Error, Equatable {
    let message: String
}

enum EnsureAssets {

    /// Ensure the on-device Speech model assets for the user's current locale are
    /// installed, reporting real download progress via `onProgress`.
    ///
    /// - Parameters:
    ///   - which: which asset family to install. Phase 3 supports only `"speech"`.
    ///   - onProgress: called with real fractions in `[0, 1]` as installation
    ///     advances. Guaranteed to receive at least `0.0` (start) and `1.0`
    ///     (completion) on the success path; already-installed short-circuits to
    ///     a single `1.0`.
    /// - Returns: `true` once the assets are verified installed.
    /// - Throws: `EnsureAssetsError` with a truthful reason on unsupported
    ///   `which`, Speech unavailability, an unobtainable installation request, a
    ///   thrown download error, or a post-install verification miss. Never
    ///   reports success it cannot back with a real `installedLocales` check.
    static func run(
        which: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
        // 1. Only the Speech model family is supported in Phase 3.
        guard which == "speech" else {
            throw EnsureAssetsError(
                message: "unsupported asset family '\(which)' — only 'speech' is supported"
            )
        }

        // 2. Gate on real engine availability. If SpeechTranscriber can't run on
        //    this machine, installing its assets is pointless — say so honestly.
        guard SpeechTranscriber.isAvailable else {
            throw EnsureAssetsError(
                message: "SpeechTranscriber is not available on this device — cannot install speech assets"
            )
        }

        // 3. Already installed? Short-circuit with a single 1.0 — no redundant
        //    download. Reuses the exact membership logic Probe uses for its
        //    `speechAssetsInstalled` boolean.
        if await Probe.checkSpeechAssetsInstalled() {
            onProgress(1.0)
            return true
        }

        // 4. Resolve the locale the engine considers equivalent to the user's,
        //    falling back to the raw current locale, and build the transcriber
        //    module whose assets we want installed.
        let targetLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale.current
        let transcriber = SpeechTranscriber(locale: targetLocale, preset: .transcription)

        // 5. Ask the framework for a real installation request for that module.
        //    A nil request means the system has nothing to install for these
        //    modules; combined with the step-3 check above that is unexpected, so
        //    treat it as an honest failure rather than a silent success.
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw EnsureAssetsError(
                message: "failed to create speech asset installation request: \(error.localizedDescription)"
            )
        }
        guard let request else {
            throw EnsureAssetsError(
                message: "no speech asset installation request available for locale \(targetLocale.identifier(.bcp47)) — assets may be unsupported here"
            )
        }

        // 6. Honest floor: emit a real 0.0 start before any download work.
        onProgress(0.0)

        // 7. Observe the request's real Progress. Each callback forwards the
        //    framework's own `fractionCompleted`, clamped to [0, 1]. We retain
        //    the observation for the duration of the download and invalidate it
        //    afterwards.
        let observation = request.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { progress, _ in
            let fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
            onProgress(fraction)
        }
        defer { observation.invalidate() }

        // 8. Perform the real download + install. Any thrown error (network,
        //    ineligibility, etc.) becomes an honest EnsureAssetsError.
        do {
            try await request.downloadAndInstall()
        } catch {
            throw EnsureAssetsError(
                message: "speech asset download/install failed: \(error.localizedDescription)"
            )
        }

        // 9. Verify the install actually landed — never claim success on faith.
        guard await Probe.checkSpeechAssetsInstalled() else {
            throw EnsureAssetsError(
                message: "speech asset install completed but locale \(targetLocale.identifier(.bcp47)) is still not in installedLocales"
            )
        }

        // 10. Honest ceiling: a verified 1.0 completion.
        onProgress(1.0)
        return true
    }
}
