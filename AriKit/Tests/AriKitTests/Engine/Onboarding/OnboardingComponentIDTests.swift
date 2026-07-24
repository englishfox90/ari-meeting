//
//  OnboardingComponentIDTests.swift — acceptance test 2 (docs/plans/onboarding-install-flow.md
//  §7). A change-detector test: adding a 4th component without updating the UI row list should
//  fail loudly, not silently.
//
import Testing
@testable import AriKit

@Suite("OnboardingComponentID")
struct OnboardingComponentIDTests {
    @Test("CaseIterable covers exactly the three documented components")
    func caseIterableCoversExactlyThreeComponents() {
        #expect(
            Set(OnboardingComponentID.allCases) == [
                .diarization,
                .summaryModel,
                .embedding
            ]
        )
        #expect(OnboardingComponentID.allCases.count == 3)
    }
}
