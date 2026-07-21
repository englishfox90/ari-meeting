//
//  MarginaliaTimecode.swift — shared MM:SS timecode formatter (plan §5 Wave 0,
//  docs/plans/arikit-component-library.md).
//
//  Extracted verbatim from the private `timecode` statics in `AudioPlayerBar` and
//  `TranscriptListView` — a third caller (Tier 2 extraction) is coming, so this is DRY'd
//  first. Pure, Sendable, no domain dependency.
//
import Foundation

public enum MarginaliaTimecode {
    /// Formats a duration in seconds as `MM:SS`, rounding to the nearest whole second.
    public static func mmss(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
