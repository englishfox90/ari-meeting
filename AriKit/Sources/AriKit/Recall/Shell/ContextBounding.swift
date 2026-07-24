//
//  ContextBounding.swift — bounded-context assembly (plan §7, ← shell.rs:105-268).
//
//  All text comes from the local database. These transforms bound a broad query so it cannot turn
//  into an unbounded local-model request: a head/tail middle-excerpt, per-source budgets, a
//  per-meeting source cap, and a history window. Ported bit-for-bit from the frozen Rust source —
//  counting in Unicode scalars to match Rust `chars()` arithmetic exactly.
//
import Foundation

public extension Recall {

    // MARK: - Middle excerpt

    /// Keep the opening and the conclusion, eliding the middle (← `bounded_middle_excerpt`). When
    /// the text is within `maximum` scalars it is returned unchanged; otherwise a `head` (first
    /// `maximum/2` scalars) and `tail` (remaining budget) are joined around an elision line.
    static func boundedMiddleExcerpt(_ text: String, max maximum: Int) -> String {
        let characters = scalars(text)
        if characters.count <= maximum {
            return text
        }
        let headLength = maximum / 2
        let tailLength = maximum - headLength
        let head = string(fromScalars: characters[..<headLength])
        let tail = string(fromScalars: characters[(characters.count - tailLength)...])
        return "\(head)\n…\n\(tail)"
    }

    // MARK: - Source assembly

    /// Meeting-scoped sources: cap to `maxSources` (keeping the edges when over), then bound each
    /// excerpt to an even per-source budget (← `build_meeting_recall_sources`).
    static func buildMeetingSources(_ matches: [TranscriptSearchResult]) -> [RecallSource] {
        let matchCount = matches.count
        let selected: [TranscriptSearchResult]
        if matchCount > RecallBounds.maxSources {
            let edgeCount = RecallBounds.maxSources / 2
            selected = matches.enumerated().compactMap { index, item in
                (index < edgeCount || index >= matchCount - edgeCount) ? item : nil
            }
        } else {
            selected = matches
        }

        let perSourceBudget: Int = selected.isEmpty
            ? RecallBounds.maxSourceChars
            : min(RecallBounds.maxContextChars / selected.count, RecallBounds.maxSourceChars)

        return selected.map { item in
            RecallSource(
                meetingId: item.id,
                title: item.title,
                matchContext: boundedMiddleExcerpt(item.matchContext, max: perSourceBudget),
                timestamp: item.timestamp,
                meetingDate: item.meetingDate,
                summary: item.summary.flatMap(summaryMarkdown),
                speakers: []
            )
        }
    }

    /// Global sources: one merged source per meeting, capped to `maxGlobalMeetings`
    /// (← `build_global_recall_sources`).
    static func buildGlobalSources(_ matches: [TranscriptSearchResult]) -> [RecallSource] {
        var sources: [RecallSource] = []
        for item in matches {
            if let existingIndex = sources.firstIndex(where: { $0.meetingId == item.id }) {
                if !sources[existingIndex].matchContext.contains(item.matchContext) {
                    let merged = "\(sources[existingIndex].matchContext)\n[\(item.timestamp)] \(item.matchContext)"
                    sources[existingIndex].matchContext =
                        boundedMiddleExcerpt(merged, max: RecallBounds.maxSourceChars)
                }
                if sources[existingIndex].summary == nil {
                    sources[existingIndex].summary = item.summary.flatMap(summaryMarkdown)
                }
                continue
            }
            if sources.count >= RecallBounds.maxGlobalMeetings {
                continue
            }
            sources.append(
                RecallSource(
                    meetingId: item.id,
                    title: item.title,
                    matchContext: "[\(item.timestamp)] \(item.matchContext)",
                    timestamp: item.timestamp,
                    meetingDate: item.meetingDate,
                    summary: item.summary.flatMap(summaryMarkdown),
                    speakers: []
                )
            )
        }
        return sources
    }

    // MARK: - Summary extraction

    /// Extract renderable markdown from a saved summary's raw JSON (← `summary_markdown`). A bare
    /// JSON string is used directly; an object with a `"markdown"` string uses that; legacy
    /// plain-text (non-JSON) is used as-is; any other JSON value is pretty-printed with
    /// `english_cache` removed. Returns `nil` for empty input/result.
    ///
    /// Parity note: the pretty-print branch (a summary object with no `"markdown"` key) is not
    /// exercised by any Slice-1 test; Foundation's `JSONSerialization` pretty output is used as the
    /// closest available equivalent to serde_json's `to_string_pretty` (2-space indent, sorted
    /// keys). Byte-for-byte formatting of that branch is not guaranteed — flagged for review.
    static func summaryMarkdown(_ raw: String) -> String? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.isEmpty {
            return nil
        }

        let summary: String
        let data = Data(trimmedRaw.utf8)
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let stringValue = json as? String {
                summary = stringValue
            } else if var object = json as? [String: Any] {
                if let markdown = object["markdown"] as? String {
                    summary = markdown
                } else {
                    object.removeValue(forKey: "english_cache")
                    guard let pretty = prettyPrinted(object) else { return nil }
                    summary = pretty
                }
            } else {
                // Arrays / numbers / bools / null: Rust serializes the value verbatim.
                guard let pretty = prettyPrinted(json) else { return nil }
                summary = pretty
            }
        } else {
            summary = trimmedRaw
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.isEmpty {
            return nil
        }
        return boundedMiddleExcerpt(trimmedSummary, max: RecallBounds.maxSourceChars)
    }

    private static func prettyPrinted(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - History

    /// Assemble the last `maxHistoryTurns` turns into a bounded block (← `build_local_recall_history`).
    /// Only `user`/`assistant` roles are accepted; any other role throws (never trusted). Empty
    /// turns are skipped.
    static func buildHistory(_ turns: [RecallTurn]) throws -> String {
        let start = turns.count - min(turns.count, RecallBounds.maxHistoryTurns)
        var lines: [String] = []
        for turn in turns[start...] {
            let role: String
            switch turn.role {
            case "user": role = "User"
            case "assistant": role = "Local assistant"
            default: throw RecallError.unsupportedHistoryRole
            }
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                continue
            }
            lines.append("\(role): \(content)")
        }
        return boundedMiddleExcerpt(lines.joined(separator: "\n"), max: RecallBounds.maxHistoryChars)
    }

    // MARK: - Context

    /// Render the numbered `[Source N | …]` context blocks, printing each meeting's saved summary
    /// at most once, then bound the whole thing (← `build_local_recall_context`).
    ///
    /// `source.meetingDate` is a raw RFC3339 UTC instant on the wire type (kept unchanged so the UI
    /// layer's own `RecallCardDisplay.friendlyDate` re-formatting still works). Here it is converted
    /// to an already-correct LOCAL-timezone human string BEFORE it reaches the model — never handed
    /// over as a raw `…T14:46:29Z` for the LLM to (wrongly) timezone-shift itself (the live
    /// 2026-07-23 "2:46 PM" bug). `source.timestamp` is a within-recording offset label
    /// ("00:05"/"not available"), NOT a wall-clock date, so it is printed verbatim. `timeZone`/
    /// `locale` default to the device's current values; injectable so the conversion is testable
    /// independent of the CI machine's own zone.
    static func buildContext(
        _ sources: [RecallSource],
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        var summariesIncluded = Set<String>()
        let blocks = sources.enumerated().map { index, source -> String in
            let meetingDate = RecallCardDisplay.friendlyDate(
                source.meetingDate,
                timeZone: timeZone,
                locale: locale
            ) ?? "date unavailable"
            var summarySection = ""
            // Rust `.filter(|_| insert(...))`: `insert` runs (and thus the meeting is marked seen)
            // ONLY when a summary is present — the short-circuit here preserves that.
            if let summary = source.summary, summariesIncluded.insert(source.meetingId).inserted {
                summarySection = "\nSaved summary:\n\(summary)"
            }
            var transcriptSection = ""
            if !source.matchContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptSection = "\nTranscript excerpt:\n\(source.matchContext)"
            }
            return "[Source \(index + 1) | \(source.title) | meeting date \(meetingDate) | transcript time \(source.timestamp)]\(summarySection)\(transcriptSection)"
        }
        return boundedMiddleExcerpt(blocks.joined(separator: "\n\n"), max: RecallBounds.maxContextChars)
    }
}
