//
//  STTLocaleTests.swift — plan §6 Slice A (← Transcribe.swift:100-103).
//
import Foundation
import Testing
@testable import AriKit

struct STTLocaleTests {
    @Test func nilResolvesToCurrentLocale() {
        #expect(STTLocale.resolveRequestedLocale(nil) == Locale.current)
    }

    @Test func emptyStringResolvesToCurrentLocale() {
        #expect(STTLocale.resolveRequestedLocale("") == Locale.current)
    }

    @Test func autoSentinelIsCaseInsensitiveAndResolvesToCurrentLocale() {
        #expect(STTLocale.resolveRequestedLocale("auto") == Locale.current)
        #expect(STTLocale.resolveRequestedLocale("AUTO") == Locale.current)
        #expect(STTLocale.resolveRequestedLocale("Auto") == Locale.current)
    }

    @Test func autoTranslateSentinelIsCaseInsensitiveAndResolvesToCurrentLocale() {
        #expect(STTLocale.resolveRequestedLocale("auto-translate") == Locale.current)
        #expect(STTLocale.resolveRequestedLocale("AUTO-TRANSLATE") == Locale.current)
        #expect(STTLocale.resolveRequestedLocale("Auto-Translate") == Locale.current)
    }

    @Test func explicitIdentifierResolvesToThatLiteralLocale() {
        #expect(STTLocale.resolveRequestedLocale("en-US") == Locale(identifier: "en-US"))
        #expect(STTLocale.resolveRequestedLocale("fr-FR") == Locale(identifier: "fr-FR"))
    }
}
