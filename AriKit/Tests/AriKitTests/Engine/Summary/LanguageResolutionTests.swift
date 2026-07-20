//
//  LanguageResolutionTests.swift — plan §6 Slice F (← summary/processor.rs `#[cfg(test)]`:
//  `language_name_from_code` + `resolve_final_language_action`).
//
import Testing
@testable import AriKit

struct LanguageResolutionTests {

    // MARK: - languageName(fromCode:)

    @Test func recognizesCommonLanguageCodes() {
        #expect(LanguageResolution.languageName(fromCode: "en") == "English")
        #expect(LanguageResolution.languageName(fromCode: "fr") == "French")
        #expect(LanguageResolution.languageName(fromCode: "ja") == "Japanese")
        #expect(LanguageResolution.languageName(fromCode: "de") == "German")
    }

    @Test func normalizesRegionalVariants() {
        #expect(LanguageResolution.languageName(fromCode: "pt-BR") == "Portuguese")
        #expect(LanguageResolution.languageName(fromCode: "en_GB") == "English")
        #expect(LanguageResolution.languageName(fromCode: "EN") == "English")
    }

    @Test func disambiguatesChineseVariants() {
        #expect(LanguageResolution.languageName(fromCode: "zh-CN") == "Chinese")
        #expect(LanguageResolution.languageName(fromCode: "zh-TW") == "Traditional Chinese")
        #expect(LanguageResolution.languageName(fromCode: "zh") == "Chinese")
    }

    @Test func unknownCodeReturnsNil() {
        #expect(LanguageResolution.languageName(fromCode: "zz-unknown") == nil)
    }

    // MARK: - resolveFinalLanguageAction matrix (← the four `#[cfg(test)]` cases)

    @Test func englishTargetWithEnglishTranscriptSkipsNormalization() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(summaryLanguage: "en", detectedTranscriptLanguage: "en")
                == .returnEnglish
        )
    }

    @Test func englishTargetWithNonEnglishTranscriptNormalizesToEnglish() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(summaryLanguage: "en", detectedTranscriptLanguage: "ja")
                == .normalizeEnglish
        )
    }

    @Test func englishTargetWithUnknownTranscriptNormalizesToEnglish() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(summaryLanguage: "en", detectedTranscriptLanguage: nil)
                == .normalizeEnglish
        )
    }

    @Test func nonEnglishTargetUsesTranslationFlow() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(summaryLanguage: "fr", detectedTranscriptLanguage: "ja")
                == .translate("French")
        )
    }

    @Test func noSummaryLanguageWithEnglishTranscriptReturnsEnglish() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(summaryLanguage: nil, detectedTranscriptLanguage: "en")
                == .returnEnglish
        )
    }

    @Test func unknownSummaryLanguageCodeFallsBackToDetectedTranscript() {
        #expect(
            LanguageResolution.resolveFinalLanguageAction(
                summaryLanguage: "zz-unknown",
                detectedTranscriptLanguage: "en"
            )
                == .returnEnglish
        )
    }
}
