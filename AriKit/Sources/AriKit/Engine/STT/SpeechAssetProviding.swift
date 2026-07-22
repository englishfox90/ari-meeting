//
//  SpeechAssetProviding.swift — the injectable seam for on-device speech-asset queries/installs.
//
//  Lets UI (`SettingsViewModel`) depend on an ABSTRACTION instead of the concrete
//  `SpeechAssetManager`, so headless tests inject a deterministic double and never touch the real
//  `Speech.framework` (mirrors `SpeechTranscriberProvider`'s injectable locale/installed seams).
//  Production wires the real `SpeechAssetManager`, which conforms below.
//
import Foundation

/// Availability + on-demand install of the on-device `SpeechTranscriber` model assets, abstracted
/// so callers (and tests) don't bind to the concrete framework-backed implementation.
public protocol SpeechAssetProviding: Sendable {
    /// Whether the on-device speech engine can run on this machine at all.
    func isEngineAvailable() -> Bool
    /// Every locale the engine can transcribe (empty when unavailable).
    func supportedLocales() async -> [Locale]
    /// Whether the model assets for `forLocale` (or the resolved current locale, if `nil`/empty)
    /// are installed.
    func areAssetsInstalled(forLocale: String?) async -> Bool
    /// Install the model assets for `forLocale`, reporting real progress via `onProgress`. Throws
    /// a `TranscriptionError` on any failure rather than claiming an unverified success.
    func install(forLocale: String?, onProgress: @escaping @Sendable (Double) -> Void) async throws
}

extension SpeechAssetManager: SpeechAssetProviding {}
