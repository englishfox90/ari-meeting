//
//  Probe.swift
//  apple-helper
//
//  Availability logic for the `probe` request, factored out of main.swift so it
//  is unit-testable. Every returned boolean reflects a REAL runtime query
//  against the Speech and FoundationModels frameworks — never a hardcoded
//  optimistic value (No-Fake-State). If a framework call throws or a reason is
//  unrecognized, we degrade conservatively to `false` and never crash.
//
//  Symbols verified against the macOS 26 SDK swiftinterface:
//    - FoundationModels: `SystemLanguageModel.default.availability` →
//      `Availability` = `.available` | `.unavailable(UnavailableReason)` with
//      `.deviceNotEligible` / `.appleIntelligenceNotEnabled` / `.modelNotReady`.
//    - Speech: `SpeechTranscriber.isAvailable: Bool` (sync),
//      `SpeechTranscriber.installedLocales: [Locale]` (async),
//      `SpeechTranscriber.supportedLocale(equivalentTo:)` (async).
//

import Foundation
import FoundationModels
import Speech

/// The five booleans a `probe` reports, mirroring `AppleResponse.probeResult`.
struct ProbeResult: Equatable {
    let speechAvailable: Bool
    let foundationAvailable: Bool
    let osOk: Bool
    let appleIntelligence: Bool
    let speechAssetsInstalled: Bool
}

enum Probe {

    /// Compute the probe result by querying the real frameworks.
    ///
    /// `async` because the Speech asset queries (`installedLocales`,
    /// `supportedLocale(equivalentTo:)`) are async. `main.swift` bridges this to
    /// its synchronous read loop with a semaphore.
    static func run() async -> ProbeResult {
        let osOk = checkOSVersion()
        let (foundationAvailable, appleIntelligence) = checkFoundationModels()
        let speechAvailable = checkSpeechAvailable()
        let speechAssetsInstalled = await checkSpeechAssetsInstalled()

        return ProbeResult(
            speechAvailable: speechAvailable,
            foundationAvailable: foundationAvailable,
            osOk: osOk,
            appleIntelligence: appleIntelligence,
            speechAssetsInstalled: speechAssetsInstalled
        )
    }

    // MARK: - OS version

    /// Real runtime check: macOS 26.0 or newer.
    static func checkOSVersion() -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    // MARK: - FoundationModels (on-device LLM)

    /// Derive `(foundationAvailable, appleIntelligence)` from the system
    /// language model's availability. Mapping (per spec):
    ///   - `.available`                                 → (true,  true)
    ///   - `.unavailable(.appleIntelligenceNotEnabled)` → (false, false)
    ///   - `.unavailable(.deviceNotEligible)`           → (false, false)
    ///   - `.unavailable(.modelNotReady)`               → (false, true)
    ///        (Apple Intelligence IS enabled, model still downloading.)
    ///   - any other/unknown reason                     → (false, false) conservative
    static func checkFoundationModels() -> (foundationAvailable: Bool, appleIntelligence: Bool) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, true)
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return (false, false)
            case .deviceNotEligible:
                return (false, false)
            case .modelNotReady:
                return (false, true)
            @unknown default:
                // Unrecognized reason from a future OS: stay conservative.
                return (false, false)
            }
        @unknown default:
            // Unrecognized availability case from a future OS: stay conservative.
            return (false, false)
        }
    }

    // MARK: - Speech (SpeechAnalyzer / SpeechTranscriber STT)

    /// Whether the new SpeechTranscriber STT engine is usable on this machine.
    /// `SpeechTranscriber.isAvailable` is a synchronous static Bool.
    static func checkSpeechAvailable() -> Bool {
        SpeechTranscriber.isAvailable
    }

    /// Whether the speech model assets for the current locale are already
    /// installed locally. We resolve the current locale to its supported
    /// equivalent, then check membership in `SpeechTranscriber.installedLocales`
    /// (compared by BCP-47 identifier). Degrades to `false` on any mismatch.
    static func checkSpeechAssetsInstalled() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else { return false }

        // Prefer the locale the engine considers equivalent to the user's; fall
        // back to the raw current locale if no equivalent is reported.
        let target = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale.current
        let targetID = target.identifier(.bcp47)

        return installed.contains { $0.identifier(.bcp47) == targetID }
    }
}
