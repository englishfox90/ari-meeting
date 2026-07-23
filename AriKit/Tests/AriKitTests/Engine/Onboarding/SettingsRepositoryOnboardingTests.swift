//
//  SettingsRepositoryOnboardingTests.swift — acceptance test 3 (docs/plans/
//  onboarding-install-flow.md §7). Extends the existing `SettingsRepository` test suite's
//  pattern (`SettingsRepositoryTests.swift`) rather than inventing a new one.
//
import Testing
@testable import AriKit

@Suite("SettingsRepository .onboardingCompleted")
struct SettingsRepositoryOnboardingTests {
    @Test("bool(forKey: .onboardingCompleted) returns nil before any write, never a fabricated false")
    func returnsNilBeforeAnyWrite() async throws {
        let db = try AppDatabase.makeInMemory()
        let value = try await db.settings.bool(forKey: .onboardingCompleted)
        #expect(value == nil)
    }

    @Test("true after setBool(true, forKey: .onboardingCompleted)")
    func returnsTrueAfterWrite() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setBool(true, forKey: .onboardingCompleted)
        let value = try await db.settings.bool(forKey: .onboardingCompleted)
        #expect(value == true)
    }
}
