//
//  HardwareCapability.swift — real hardware readout for the first-run install flow (docs/plans/
//  onboarding-install-flow.md §2.5). Pure, testable (no real-hardware dependency needed to test
//  `HardwareAssessment.assessSummaryModelComfort`), informational-only per the product owner's
//  explicit direction — this NEVER blocks continuing.
//
//  Deliberately no "chip name" (M1/M2/M3…) lookup — there is no stable public API mapping
//  `sysctlbyname("hw.model")` to a marketing chip name without a hand-maintained table that goes
//  stale every hardware refresh (brand/BRAND.md §2, "Numbers are exact or absent — never rounded
//  theatrics"). RAM + core count is honest and sufficient.
//
import Foundation

public struct HardwareCapability: Sendable, Equatable {
    /// `ProcessInfo.processInfo.physicalMemory` converted from bytes to GB (decimal, /1e9 — not
    /// /1024^3 — matching the old Rust flow's `get_system_ram_gb()` convention).
    public let physicalMemoryGB: Double
    public let processorCount: Int
    /// Always `true` on this platform floor (`.claude/rules/platform-and-deps.md` — Apple Silicon
    /// only) — kept as a field mostly so the type is self-documenting and the assessment logic
    /// doesn't silently assume it.
    public let isAppleSilicon: Bool

    public init(physicalMemoryGB: Double, processorCount: Int, isAppleSilicon: Bool) {
        self.physicalMemoryGB = physicalMemoryGB
        self.processorCount = processorCount
        self.isAppleSilicon = isAppleSilicon
    }

    public static func current() -> HardwareCapability {
        HardwareCapability(
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1e9,
            processorCount: ProcessInfo.processInfo.processorCount,
            isAppleSilicon: true
        )
    }
}

public enum SummaryModelComfort: Sendable, Equatable {
    case comfortable
    case belowComfortThreshold(recommendedGB: Double)
}

public enum HardwareAssessment {
    /// Pure function (testable without touching real hardware): informational only, per the
    /// product owner's explicit direction — NEVER used to block continuing.
    ///
    /// `thresholdGB` default resolved 2026-07-23 (plan "Decisions"): 16 GB for the on-device MLX
    /// Qwen3.5-4B-4bit summary model. Boundary-inclusive: exactly `thresholdGB` counts as
    /// `.comfortable`, only strictly below it is a soft warning.
    public static func assessSummaryModelComfort(
        _ capability: HardwareCapability,
        thresholdGB: Double = 16.0
    ) -> SummaryModelComfort {
        capability.physicalMemoryGB >= thresholdGB
            ? .comfortable
            : .belowComfortThreshold(recommendedGB: thresholdGB)
    }
}
