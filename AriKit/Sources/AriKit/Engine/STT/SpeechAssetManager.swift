//
//  SpeechAssetManager.swift — SpeechTranscriber asset availability/install (plan §2.5, Slice B).
//
//  Absorbs `apple-helper`'s `EnsureAssets.swift` + the asset half of `Probe.swift` IN-PROCESS
//  (the sidecar hop vanishes, same pattern as `AppleNLEmbedder`/`FoundationModelsClient`). The
//  Rust `whisper_engine`/`parakeet_engine` download managers fetched multi-GB weights from
//  Hugging Face into the app-data dir and managed their lifecycle; under SpeechAnalyzer those
//  assets are OS-managed — `AssetInventory.assetInstallationRequest(supporting:)` +
//  `downloadAndInstall()` hand the download to the system. No HF URL, no model-dir bookkeeping,
//  no cache eviction to port (subsystem-map "Partly dissolves").
//
//  Symbols verified against the macOS 26 SDK swiftinterface (Speech.framework), reused verbatim
//  from EnsureAssets.swift/Probe.swift headers — not re-derived:
//    - `SpeechTranscriber.isAvailable: Bool` (static, sync)
//    - `SpeechTranscriber.installedLocales: [Locale]` (static, async)
//    - `SpeechTranscriber.supportedLocale(equivalentTo:) -> Locale?`
//    - `SpeechTranscriber(locale:preset:)` convenience init
//    - `AssetInventory.assetInstallationRequest(supporting: [any SpeechModule]) async throws
//         -> AssetInstallationRequest?`
//    - `AssetInstallationRequest: ProgressReporting` with `var progress: Foundation.Progress` and
//         `func downloadAndInstall() async throws`
//
//  No-Fake-State (plan §7): `install(forLocale:onProgress:)` reports an honest 0.0 floor, then the
//  framework's OWN `Progress.fractionCompleted` verbatim (never interpolated), and only reports a
//  final 1.0 after a REAL post-install `installedLocales` re-check. On any failure (engine
//  unavailable, no installation request obtainable, a thrown download error, or a post-install
//  verification miss) this THROWS a descriptive `TranscriptionError` rather than claiming success.
//
import Foundation
import Speech

/// Availability + on-demand install manager for the on-device `SpeechTranscriber` model assets.
/// Stateless (holds no mutable state — every call queries the live framework), so `Sendable` for
/// free like the rest of the provider layer (`arikit-engine-providers.md §3`).
public struct SpeechAssetManager: Sendable {
    public init() {}

    /// Whether the `SpeechTranscriber` STT engine is usable on this machine at all. ←
    /// `Probe.checkSpeechAvailable` — a synchronous static Bool, no fabrication possible.
    public func isEngineAvailable() -> Bool {
        SpeechTranscriber.isAvailable
    }

    /// Whether the speech model assets for `forLocale` (or the resolved current locale sentinel,
    /// `STTLocale.resolveRequestedLocale`, if `nil`/empty) are already installed. Resolves the
    /// locale the engine considers equivalent, then checks membership in
    /// `SpeechTranscriber.installedLocales` by BCP-47 identifier (← `Probe.checkSpeechAssetsInstalled`).
    /// Degrades to `false` on any mismatch or when the engine itself is unavailable — never fakes
    /// an "installed" answer.
    public func areAssetsInstalled(forLocale: String?) async -> Bool {
        guard isEngineAvailable() else { return false }

        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else { return false }

        let requested = STTLocale.resolveRequestedLocale(forLocale)
        let target = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
        let targetID = target.identifier(.bcp47)

        return installed.contains { $0.identifier(.bcp47) == targetID }
    }

    /// Install the on-device speech model assets for `forLocale` (or the resolved current-locale
    /// sentinel if `nil`/empty), reporting REAL download progress via `onProgress`.
    ///
    /// Guarantees on the success path: `onProgress` is called with an honest `0.0` before any
    /// download work, then zero-or-more of the framework's own `Progress.fractionCompleted`
    /// fractions (Apple does not contractually guarantee intermediate granularity — a
    /// small/cached asset may jump straight from nothing to installed), and finally a verified
    /// `1.0` only after a REAL post-install `installedLocales` re-check. Already-installed
    /// short-circuits to a single `1.0` — no redundant download.
    ///
    /// - Throws: `TranscriptionError.providerUnavailable` if `SpeechTranscriber` cannot run on
    ///   this device; `TranscriptionError.unsupportedLanguage` if the locale has no supported
    ///   equivalent; `TranscriptionError.engineFailed` if the installation request could not be
    ///   obtained, the download/install throws, or the post-install verification still shows the
    ///   locale missing. Never reports success it cannot back with a real check (No-Fake-State).
    public func install(
        forLocale: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // 1. Gate on real engine availability — installing assets for an engine that can't run
        //    on this device is pointless; say so honestly (← EnsureAssets.swift step 2).
        guard isEngineAvailable() else {
            throw TranscriptionError.providerUnavailable(
                "SpeechTranscriber is not available on this device — cannot install speech assets"
            )
        }

        // 2. Already installed? Short-circuit with a single 1.0 — no redundant download (←
        //    EnsureAssets.swift step 3).
        if await areAssetsInstalled(forLocale: forLocale) {
            onProgress(1.0)
            return
        }

        // 3. Resolve the locale the engine considers equivalent to the requested one (← EnsureAssets
        //    step 4). An honest miss (no supported equivalent at all) is `.unsupportedLanguage`,
        //    never a silently-wrong-locale install.
        let requested = STTLocale.resolveRequestedLocale(forLocale)
        guard let targetLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLanguage(requested.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(locale: targetLocale, preset: .transcription)

        // 4. Ask the framework for a real installation request for that module (← EnsureAssets
        //    step 5). A nil request combined with the step-2 not-installed check is unexpected —
        //    treat it as an honest failure rather than a silent success.
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw TranscriptionError.engineFailed(
                "failed to create speech asset installation request: \(error.localizedDescription)"
            )
        }
        guard let request else {
            throw TranscriptionError.engineFailed(
                "no speech asset installation request available for locale \(targetLocale.identifier(.bcp47)) — assets may be unsupported here"
            )
        }

        // 5. Honest floor: emit a real 0.0 start before any download work (← EnsureAssets step 6).
        onProgress(0.0)

        // 6. Observe the request's real Progress, forwarding the framework's own fractions
        //    verbatim, clamped to [0, 1]. Invalidated in a `defer` (← EnsureAssets steps 7).
        let observation = request.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { progress, _ in
            let fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
            onProgress(fraction)
        }
        defer { observation.invalidate() }

        // 7. Perform the real download + install (← EnsureAssets step 8).
        do {
            try await request.downloadAndInstall()
        } catch {
            throw TranscriptionError.engineFailed(
                "speech asset download/install failed: \(error.localizedDescription)"
            )
        }

        // 8. Verify the install actually landed — never claim success on faith (← EnsureAssets
        //    step 9).
        guard await areAssetsInstalled(forLocale: forLocale) else {
            throw TranscriptionError.engineFailed(
                "speech asset install completed but locale \(targetLocale.identifier(.bcp47)) is still not in installedLocales"
            )
        }

        // 9. Honest ceiling: a verified 1.0 completion (← EnsureAssets step 10).
        onProgress(1.0)
    }
}
