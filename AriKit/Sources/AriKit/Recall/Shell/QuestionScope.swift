//
//  QuestionScope.swift — out-of-scope refusal (plan §7, ← shell.rs:34).
//
//  Refuses only truly out-of-scope external capabilities. Calendar is deliberately NOT here: Ask
//  injects linked calendar-event context, so calendar-topic questions are answered best-effort
//  rather than hard-refused. `"account"`/`"drive"` were dropped as too false-positive-prone.
//
import Foundation

extension Recall {
    /// Whether `question` asks for a capability outside saved local transcripts
    /// (← `is_unsupported_recall_question`). Case-insensitive substring match on the exact
    /// Rust term list.
    public static func isUnsupportedRecallQuestion(_ question: String) -> Bool {
        let lowered = question.lowercased()
        return unsupportedTerms.contains { lowered.contains($0) }
    }

    private static let unsupportedTerms = [
        "email",
        "inbox",
        "internet",
        "web search",
        "browser",
        "file system",
        "filesystem"
    ]
}
