//
//  LanguageResolution.swift — BCP-47 → LLM-prompt language names + the final-language action
//  matrix (plan §2.4, ← summary/processor.rs `language_name_from_code` +
//  `resolve_final_language_action`).
//
//  The Rust translation-cache decision (`resolve_cached_english`, `service.rs`) is DROPPED per the
//  plan's resolved decision (§4/§9(2)): the fresh `summary` table persists only the English body +
//  provenance, recomputing translations on demand. `SummaryGenerator` therefore always starts from
//  a fresh pass 1 — only the final-language action matrix below is ported.
//
import Foundation

/// ← `FinalLanguageAction` (`processor.rs`).
public enum FinalLanguageAction: Equatable, Sendable {
    case returnEnglish
    case normalizeEnglish
    case translate(String)
}

public enum LanguageResolution {
    /// Maps a BCP-47 tag to the English language name used inside LLM prompts
    /// (← `language_name_from_code`). LLMs respond far more reliably to "in Spanish" than to "in
    /// es". Regional tags (`pt-BR`, `en_GB`) are normalised to their base language; Chinese
    /// variants are disambiguated. Unknown codes return `nil` so the caller falls back to English
    /// rather than injecting a literal ISO code into the prompt.
    public static func languageName(fromCode code: String) -> String? {
        let normalised = code.lowercased().replacingOccurrences(of: "_", with: "-")

        let lookup: String
        switch normalised {
        case "zh-cn":
            lookup = "zh"
        case "zh-tw":
            return "Traditional Chinese"
        default:
            lookup = normalised.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalised
        }

        switch lookup {
        case "en": return "English"
        case "zh": return "Chinese"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        case "ko": return "Korean"
        case "fr": return "French"
        case "ja": return "Japanese"
        case "pt": return "Portuguese"
        case "it": return "Italian"
        case "nl": return "Dutch"
        case "pl": return "Polish"
        case "ar": return "Arabic"
        case "hi": return "Hindi"
        case "ta": return "Tamil"
        case "tr": return "Turkish"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        case "id": return "Indonesian"
        case "sv": return "Swedish"
        case "cs": return "Czech"
        case "da": return "Danish"
        case "fi": return "Finnish"
        case "el": return "Greek"
        case "he": return "Hebrew"
        case "hu": return "Hungarian"
        case "no": return "Norwegian"
        case "ro": return "Romanian"
        case "uk": return "Ukrainian"
        default: return nil
        }
    }

    /// ← `resolve_final_language_action`. `summaryLanguage` (the user's requested output language)
    /// wins whenever it resolves to a non-English name (→ `.translate`); otherwise the detected
    /// transcript language decides whether pass 1 is already English (→ `.returnEnglish`) or needs
    /// a soft normalization pass (→ `.normalizeEnglish`, the default when detection is unknown).
    public static func resolveFinalLanguageAction(
        summaryLanguage: String?,
        detectedTranscriptLanguage: String?
    ) -> FinalLanguageAction {
        if let code = summaryLanguage, let name = languageName(fromCode: code), name != "English" {
            return .translate(name)
        }
        if let code = detectedTranscriptLanguage, languageName(fromCode: code) == "English" {
            return .returnEnglish
        }
        return .normalizeEnglish
    }
}
