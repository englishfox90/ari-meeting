//
//  AskAnswerTokenizer.swift — pure tokenizer for a RecallEngine-reconciled answer string
//  (docs/plans/ari-ask-ui.md §2/§10 test 14).
//
//  The engine already verifies citations before the UI ever sees the answer (plan §0):
//  invalid `[S<n>]` and out-of-range/global `@ref(MM:SS)` markers are already stripped by
//  `RecallEngine.reconcile`. This tokenizer does NOT re-verify anything — it only splits the
//  already-safe string into displayable segments. Resolving `citation(index:)` against a row's
//  `sources` (and rendering a literal fallback if `index` is out of range) is the VIEW's job
//  (`AskAnswerText`, app target) — purely defensive, since the engine should never hand back an
//  unreconciled index.
//
import Foundation

/// One piece of a tokenized assistant answer, in original left-to-right order.
public enum AskAnswerSegment: Hashable, Sendable {
    /// A plain text run (may itself contain markdown — the view is responsible for markdown
    /// rendering, this type only knows about citation/timestamp markers).
    case text(String)
    /// A `[S<n>]` citation marker — 1-based, matching `sources[index - 1]` at the view layer.
    case citation(index: Int)
    /// A `@ref(MM:SS)` (or legacy bare `[MM:SS]`) in-meeting timestamp marker, display-only.
    case timestamp(String)
}

/// Pure, stateless tokenizer — safe to call from any isolation domain (no captured state).
public enum AskAnswerTokenizer {
    /// Matches, in one pass: `[S<digits>]` (capture group 1), `@ref(MM:SS)` (capture group 2), or
    /// a legacy bare `[MM:SS]` (capture group 3). Built once; `NSRegularExpression` is `Sendable`
    /// via `@unchecked Sendable` in Foundation itself, but this tokenizer never mutates it after
    /// construction, so no additional annotation is needed here.
    private static let regex: NSRegularExpression = {
        let pattern = #"\[S(\d+)\]|@ref\((\d{1,2}:\d{2})\)|\[(\d{1,2}:\d{2})\]"#
        // A hardcoded, compile-time-constant pattern — a throw here would only ever be a
        // programmer error caught immediately by the test suite, so `try!` is appropriate.
        return try! NSRegularExpression(pattern: pattern) // swiftlint:disable:this force_try
    }()

    /// Splits `answer` into ordered segments: interleaved plain-text runs and citation/timestamp
    /// markers. Empty text runs between adjacent markers are omitted.
    public static func tokenize(_ answer: String) -> [AskAnswerSegment] {
        var segments: [AskAnswerSegment] = []
        let fullRange = NSRange(answer.startIndex..., in: answer)
        var cursor = answer.startIndex

        let matches = regex.matches(in: answer, range: fullRange)
        for match in matches {
            guard let matchRange = Range(match.range, in: answer) else { continue }
            if matchRange.lowerBound > cursor {
                segments.append(.text(String(answer[cursor ..< matchRange.lowerBound])))
            }
            if let citationRange = Range(match.range(at: 1), in: answer), let index = Int(answer[citationRange]) {
                segments.append(.citation(index: index))
            } else if let refRange = Range(match.range(at: 2), in: answer) {
                segments.append(.timestamp(String(answer[refRange])))
            } else if let bareRange = Range(match.range(at: 3), in: answer) {
                segments.append(.timestamp(String(answer[bareRange])))
            }
            cursor = matchRange.upperBound
        }
        if cursor < answer.endIndex {
            segments.append(.text(String(answer[cursor...])))
        }
        return segments
    }
}
