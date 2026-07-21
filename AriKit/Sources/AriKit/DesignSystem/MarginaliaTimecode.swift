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

    /// Like `mmss`, but promotes to `H:MM:SS` once the duration reaches an hour, so a citation at
    /// 1:02:03 doesn't render as the ambiguous `62:03`.
    public static func label(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        guard totalSeconds >= 3600 else { return mmss(seconds) }
        return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    }
}
