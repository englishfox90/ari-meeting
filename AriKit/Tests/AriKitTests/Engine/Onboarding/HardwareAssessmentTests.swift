//
//  HardwareAssessmentTests.swift — acceptance test 1 (docs/plans/onboarding-install-flow.md §7).
//  Pure function, no real-hardware dependency.
//
import Testing
@testable import AriKit

@Suite("HardwareAssessment")
struct HardwareAssessmentTests {
    @Test("above the threshold is comfortable")
    func aboveThresholdIsComfortable() {
        let capability = HardwareCapability(physicalMemoryGB: 32.0, processorCount: 10, isAppleSilicon: true)
        #expect(HardwareAssessment.assessSummaryModelComfort(capability, thresholdGB: 16.0) == .comfortable)
    }

    @Test("exactly at the threshold is comfortable (boundary-inclusive)")
    func atThresholdIsComfortable() {
        let capability = HardwareCapability(physicalMemoryGB: 16.0, processorCount: 8, isAppleSilicon: true)
        #expect(HardwareAssessment.assessSummaryModelComfort(capability, thresholdGB: 16.0) == .comfortable)
    }

    @Test("below the threshold is a soft warning, never a fabricated block")
    func belowThresholdIsSoftWarning() {
        let capability = HardwareCapability(physicalMemoryGB: 8.0, processorCount: 8, isAppleSilicon: true)
        #expect(
            HardwareAssessment.assessSummaryModelComfort(capability, thresholdGB: 16.0)
                == .belowComfortThreshold(recommendedGB: 16.0)
        )
    }

    @Test("the default threshold is the resolved 16 GB decision")
    func defaultThresholdIsSixteenGB() {
        let below = HardwareCapability(physicalMemoryGB: 15.9, processorCount: 8, isAppleSilicon: true)
        let atOrAbove = HardwareCapability(physicalMemoryGB: 16.0, processorCount: 8, isAppleSilicon: true)
        #expect(HardwareAssessment.assessSummaryModelComfort(below) == .belowComfortThreshold(recommendedGB: 16.0))
        #expect(HardwareAssessment.assessSummaryModelComfort(atOrAbove) == .comfortable)
    }

    @Test("current() reports Apple Silicon and a real memory reading")
    func currentReportsRealHardware() {
        let capability = HardwareCapability.current()
        #expect(capability.isAppleSilicon)
        #expect(capability.physicalMemoryGB > 0)
        #expect(capability.processorCount > 0)
    }
}
