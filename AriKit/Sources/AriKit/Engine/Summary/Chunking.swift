//
//  Chunking.swift — token estimation, text chunking, and LLM-output cleanup
//  (plan §2.4, ← summary/processor.rs).
//
//  `roughTokenCount`/`chunkText` operate on Unicode *scalars* (matching Rust's `char`, which is a
//  Unicode Scalar Value, not a Swift `Character`/grapheme cluster) so char-count-based sizing and
//  boundary math stay numerically identical to the Rust port for any BMP/ASCII input — the only
//  kind the summary pipeline ever chunks.
//
import Foundation

public enum Chunking {
    /// Rough token count estimation using character count (← `rough_token_count`).
    public static func roughTokenCount(_ text: String) -> Int {
        let charCount = text.unicodeScalars.count
        return Int((Double(charCount) * 0.35).rounded(.up))
    }

    /// Chunks text into overlapping segments based on token count, with smart sentence/word
    /// boundary breaks (← `chunk_text`).
    public static func chunkText(_ text: String, chunkSizeTokens: Int, overlapTokens: Int) -> [String] {
        guard !text.isEmpty, chunkSizeTokens > 0 else {
            return []
        }

        // ~2.85 chars per token (inverse of the 0.35 tokens-per-char used by `roughTokenCount`).
        let charsPerToken = 1.0 / 0.35
        let chunkSizeChars = Int((Double(chunkSizeTokens) * charsPerToken).rounded(.up))
        let overlapChars = Int((Double(overlapTokens) * charsPerToken).rounded(.up))

        let scalars = Array(text.unicodeScalars)
        let totalChars = scalars.count

        guard totalChars > chunkSizeChars else {
            return [text]
        }

        var chunks: [String] = []
        var startChar = 0
        // Step is the size of the non-overlapping part of the window.
        let step = max(chunkSizeChars - overlapChars, 1)
        let periodSpace = Array(". ".unicodeScalars)
        let space = Array(" ".unicodeScalars)

        while startChar < totalChars {
            var endChar = min(startChar + chunkSizeChars, totalChars)

            // Try to break at a sentence or word boundary for cleaner chunks.
            if endChar < totalChars {
                let searchRange = startChar ..< endChar
                if let periodEnd = lastIndex(of: periodSpace, in: scalars, range: searchRange) {
                    endChar = periodEnd
                } else if let spaceEnd = lastIndex(of: space, in: scalars, range: searchRange) {
                    endChar = spaceEnd
                }
            }

            chunks.append(String(String.UnicodeScalarView(scalars[startChar ..< endChar])))

            if endChar >= totalChars {
                break
            }

            // Move to next chunk with overlap.
            startChar += step
        }

        return chunks
    }

    /// Cleans markdown output from LLM by removing thinking tags and code fences
    /// (← `clean_llm_markdown_output`).
    public static func cleanLLMMarkdownOutput(_ markdown: String) -> String {
        let ns = markdown as NSString
        let withoutThinking = thinkingTagRegex.stringByReplacingMatches(
            in: markdown,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        let trimmed = withoutThinking.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = ["```markdown\n", "```\n"]
        let suffix = "```"

        for prefix in prefixes where trimmed.hasPrefix(prefix) && trimmed.hasSuffix(suffix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
            guard start <= end else {
                continue
            }
            return String(trimmed[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Extracts the meeting name from the first `# ` heading in markdown
    /// (← `extract_meeting_name_from_markdown`).
    public static func extractMeetingName(fromMarkdown markdown: String) -> String? {
        guard let line = markdown.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) else {
            return nil
        }
        // Rust's `trim_start_matches("# ")` strips ALL leading occurrences of "# ", not just one.
        var stripped = Substring(line)
        while stripped.hasPrefix("# ") {
            stripped = stripped.dropFirst(2)
        }
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    /// Returns the index just past the last occurrence of `needle` within `range`, or `nil`
    /// (← Rust's `slice.rfind(needle)` + offset by `needle.len()`, operating on Unicode scalars
    /// rather than UTF-8 bytes).
    private static func lastIndex(
        of needle: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        range: Range<Int>
    ) -> Int? {
        guard !needle.isEmpty, needle.count <= range.count else {
            return nil
        }
        var i = range.upperBound - needle.count
        while i >= range.lowerBound {
            if Array(scalars[i ..< (i + needle.count)]) == needle {
                return i + needle.count
            }
            i -= 1
        }
        return nil
    }

    private static let thinkingTagRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: "<think(?:ing)?>.*?</think(?:ing)?>",
            options: [.dotMatchesLineSeparators]
        ) else {
            preconditionFailure("thinkingTagRegex pattern is a compile-time constant and must be valid")
        }
        return regex
    }()
}
