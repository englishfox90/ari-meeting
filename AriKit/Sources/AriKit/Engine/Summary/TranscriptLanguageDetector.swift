//
//  TranscriptLanguageDetector.swift — on-device transcript-language detection (← the Rust
//  `summary/language_detection.rs` `detect_summary_language`, which the first Swift summary
//  migration DROPPED).
//
//  Why this matters for latency: `SummaryGenerator` runs a SECOND full LLM pass
//  (`normalizeMarkdownToEnglish`) whenever `resolveFinalLanguageAction` can't confirm the
//  transcript is already English — and it can't when `detectedTranscriptLanguage` is `nil`
//  (`.normalizeEnglish` is the default). `SummaryRunner` was passing `nil`, so EVERY summary — even
//  a plainly-English one — paid for a redundant normalize pass, roughly DOUBLING generation time
//  (measured 2026-07-22: 23s pass-1 + 21s normalize = 47s). Feeding a confident "en" here lets the
//  matrix return `.returnEnglish` and skip pass 2.
//
//  Safety (No-Fake-State + conservative default): the ONLY behavioral change a detection causes is
//  skipping the normalize pass when the transcript is *confidently English*. A non-English result,
//  a low-confidence result, or `nil` all fall through to `.normalizeEnglish` — exactly today's
//  behavior — because `resolveFinalLanguageAction` consults `detectedTranscriptLanguage` solely in
//  its `.returnEnglish` branch (a detected non-English code never triggers translation; that comes
//  only from the user's `summaryLanguage` setting). So a wrong guess can at worst skip a normalize
//  on an English-ish transcript; it can never mistranslate the summary.
//
//  Uses Apple's `NLLanguageRecognizer` (instant, on-device, no LLM) rather than porting whatlang.
//  The confidence floor is deliberately stricter than the Rust whatlang gate (0.25) because NL's
//  probabilities are calibrated differently and a false "English" positive would skip a genuinely
//  needed normalize pass.
//
import Foundation
import NaturalLanguage

public enum TranscriptLanguageDetector {
    /// ← `MIN_MEANINGFUL_CHARS = 20`: too little alphabetic text to detect reliably.
    static let minMeaningfulChars = 20
    /// Dominant-hypothesis probability floor. NL-calibrated (a full meeting transcript in one
    /// language scores ≫ this); stricter than the Rust whatlang 0.25 for the reason in the header.
    static let minConfidence = 0.65

    /// The transcript's dominant language as a BCP-47 code the summary pipeline recognizes, or
    /// `nil` when the text is too short, detection isn't confident, or the language isn't a
    /// supported summary language (→ the caller keeps the conservative `.normalizeEnglish` default).
    public static func detect(_ text: String) -> String? {
        let meaningful = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        guard meaningful >= minMeaningfulChars else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }

        // Confidence gate (← `is_reliable() / confidence() < MIN_RELIABLE_CONFIDENCE`).
        let probability = recognizer.languageHypotheses(withMaximum: 3)[dominant] ?? 0
        guard probability >= minConfidence else { return nil }

        // `NLLanguage.rawValue` is a BCP-47-style code (e.g. "en", "es", "zh-Hans"); only return
        // ones `LanguageResolution` maps to a real prompt name (← the whatlang "unsupported" gate).
        let code = dominant.rawValue
        guard LanguageResolution.languageName(fromCode: code) != nil else { return nil }
        return code
    }
}
