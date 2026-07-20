//
//  STTLocale.swift — locale resolution sentinel mapping (plan §2.4, ← Transcribe.swift:100-113).
//
//  Ports the sentinel mapping exactly — the load-bearing bit that made "auto" work in the
//  sidecar: `""` / `"auto"` / `"auto-translate"` (case-insensitive) are Whisper/Parakeet
//  auto-detect sentinels, meaningless to a real `Locale`, and map to `Locale.current`. Any other
//  identifier is resolved as a literal `Locale(identifier:)`.
//
//  This is the PURE half of locale resolution (headlessly testable). The async
//  `supportedLocale(equivalentTo:)` / `installedLocales` half — which decides
//  `.unsupportedLanguage` vs `.assetsNotInstalled` — is device/asset-gated and lands with
//  `SpeechAssetManager` (Slice B) / `SpeechTranscriberProvider` (Slice C).
//
import Foundation

public enum STTLocale {
    /// Maps the app's requested language identifier to a `Locale`, applying the
    /// "auto"/"auto-translate"/empty sentinel → `Locale.current` mapping (← Transcribe.swift:100-103).
    /// `nil` is treated the same as an empty/missing identifier.
    public static func resolveRequestedLocale(_ id: String?) -> Locale {
        let normalized = (id ?? "").lowercased()
        if normalized.isEmpty || normalized == "auto" || normalized == "auto-translate" {
            return Locale.current
        }
        return Locale(identifier: id ?? "")
    }
}
