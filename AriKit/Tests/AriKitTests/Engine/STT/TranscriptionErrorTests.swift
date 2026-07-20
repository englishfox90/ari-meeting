//
//  TranscriptionErrorTests.swift — plan §6 Slice C, Lane 1 (headless, always runs).
//
//  Exercises `SpeechTranscriberProvider.transcribe(fileURL:language:)`'s honest failure paths
//  entirely through its injectable `isAvailableCheck`/`supportedLocale`/`installedLocalesCheck`
//  seams — never a real `SpeechTranscriber`/device asset — mirroring
//  `FoundationModelsAvailabilityTests`'s `unavailableReason`/`respond` seam pattern
//  (`FoundationModelsClientTests.swift`). A nonexistent `fileURL` is used throughout so any
//  accidental fall-through past the availability/locale gates into a real file-open would surface
//  as an unexpected `.audioDecodeFailed` rather than silently succeeding — the assertions on the
//  EXACT error case are what prove the transcribe path was never reached (no fabricated text).
//
import Foundation
import Testing
@testable import AriKit

/// Test-only actor recording whether the `supportedLocale`/`installedLocalesCheck` seams were
/// invoked — actor isolation (not `@unchecked Sendable`) makes cross-task recording safe under
/// strict concurrency (mirrors `ObservedMaxTokens` in `FoundationModelsClientTests.swift`).
private actor SeamCallRecorder {
    private(set) var supportedLocaleCalled = false
    private(set) var installedLocalesCalled = false

    func recordSupportedLocaleCall() {
        supportedLocaleCalled = true
    }

    func recordInstalledLocalesCall() {
        installedLocalesCalled = true
    }
}

private let unreachableFileURL = URL(fileURLWithPath: "/nonexistent/does-not-exist.wav")

struct TranscriptionErrorTests {
    @Test func unavailableEngineThrowsProviderUnavailableAndNeverResolvesLocale() async {
        let recorder = SeamCallRecorder()
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { false },
            supportedLocale: { _ in
                await recorder.recordSupportedLocaleCall()
                Issue.record("supportedLocale must never be consulted when the engine is unavailable")
                return nil
            },
            installedLocalesCheck: {
                await recorder.recordInstalledLocalesCall()
                Issue.record("installedLocales must never be consulted when the engine is unavailable")
                return []
            }
        )

        do {
            _ = try await provider.transcribe(fileURL: unreachableFileURL, language: "en-US")
            Issue.record("expected .providerUnavailable")
        } catch TranscriptionError.providerUnavailable {
            // expected — no fabricated text, no locale resolution attempted.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await recorder.supportedLocaleCalled == false)
        #expect(await recorder.installedLocalesCalled == false)
    }

    @Test func unsupportedLocaleThrowsUnsupportedLanguageAndNeverChecksInstalledAssets() async {
        let recorder = SeamCallRecorder()
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in nil },
            installedLocalesCheck: {
                await recorder.recordInstalledLocalesCall()
                Issue.record("installedLocales must never be consulted once the locale is unsupported")
                return []
            }
        )

        do {
            _ = try await provider.transcribe(fileURL: unreachableFileURL, language: "zz-ZZ")
            Issue.record("expected .unsupportedLanguage")
        } catch let TranscriptionError.unsupportedLanguage(identifier) {
            #expect(identifier.lowercased().contains("zz"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await recorder.installedLocalesCalled == false)
    }

    @Test func resolvableButUninstalledLocaleThrowsAssetsNotInstalled() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [] } // resolvable, but nothing installed on this "device"
        )

        do {
            _ = try await provider.transcribe(fileURL: unreachableFileURL, language: "en-US")
            Issue.record("expected .assetsNotInstalled")
        } catch let TranscriptionError.assetsNotInstalled(locale) {
            #expect(locale.lowercased().contains("en"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func installedButDifferentLocaleStillThrowsAssetsNotInstalled() async {
        // The engine resolves a supported locale AND reports some installed locales, but not the
        // one that was actually resolved — must still be an honest miss, never a silent
        // wrong-locale transcription attempt.
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "fr-FR")] }
        )

        do {
            _ = try await provider.transcribe(fileURL: unreachableFileURL, language: "en-US")
            Issue.record("expected .assetsNotInstalled")
        } catch TranscriptionError.assetsNotInstalled {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // ---- `isAvailable()` / `currentModel()` honest degradation ----

    @Test func isAvailableIsFalseWhenEngineUnavailable() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { false },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "en-US")] }
        )
        #expect(await provider.isAvailable() == false)
    }

    @Test func isAvailableIsFalseWhenNoLocalesInstalledEvenIfEngineIsAvailable() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [] }
        )
        #expect(await provider.isAvailable() == false)
    }

    @Test func isAvailableIsTrueWhenEngineUsableAndSomeLocaleIsInstalled() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "en-US")] }
        )
        #expect(await provider.isAvailable() == true)
    }

    @Test func currentModelIsNilWhenEngineUnavailable() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { false },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "en-US")] }
        )
        #expect(await provider.currentModel() == nil)
    }

    @Test func currentModelIsNilWhenNoSupportedLocaleEquivalentExists() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in nil },
            installedLocalesCheck: { [] }
        )
        #expect(await provider.currentModel() == nil)
    }

    @Test func currentModelReturnsResolvedBCP47IdentifierWhenAvailable() async {
        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "en-US")] }
        )
        let model = await provider.currentModel()
        #expect(model != nil)
    }

    // ---- provider identity ----

    @Test func providerNameIsSpeechAnalyzer() {
        let provider = SpeechTranscriberProvider()
        #expect(provider.providerName == "speechanalyzer")
    }
}
