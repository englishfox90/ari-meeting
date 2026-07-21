//
//  ReferencedMoments.swift — extracts citation timecodes from summary markdown.
//
//  A summary body carries inline citation markers pointing at moments in the recording, in two
//  forms: `[MM:SS]` / `[H:MM:SS]` and `@ref(MM:SS)` / `@ref(H:MM:SS)`. This pure helper pulls
//  every marker out as recording-relative seconds so the detail view can render tappable seek
//  chips. It NEVER invents a moment — an unmarked summary yields an empty list (No-Fake-State).
//
import Foundation

public enum ReferencedMoments {
    /// The recording-relative seconds of every citation marker in `markdown`, sorted ascending
    /// and de-duplicated. Empty when there are no markers.
    public static func parse(from markdown: String) -> [Double] {
        // (?:[ or @ref()  MMMM  :SS  (:SS)?  ] or )  — leading \d{1,4} matches the engine's
        // TS_BODY so a >59-minute meeting's `MMM:SS` marker (e.g. 120:45) isn't dropped.
        let pattern = "(?:\\[|@ref\\()(\\d{1,4}):([0-5]\\d)(?::([0-5]\\d))?(?:\\]|\\))"
        guard let regex = try? Regex(pattern) else { return [] }

        var seconds: Set<Double> = []
        for match in markdown.matches(of: regex) {
            let first = match.output[1].substring.flatMap { Int($0) }
            let second = match.output[2].substring.flatMap { Int($0) }
            let third = match.output[3].substring.flatMap { Int($0) }
            guard let first, let second else { continue }
            if let third {
                // H:MM:SS
                seconds.insert(Double(first * 3600 + second * 60 + third))
            } else {
                // MM:SS
                seconds.insert(Double(first * 60 + second))
            }
        }
        return seconds.sorted()
    }
}
