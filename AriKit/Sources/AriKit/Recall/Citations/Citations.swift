//
//  Citations.swift — inline citation + timestamp verification (plan §7, ← citations.rs).
//
//  The model is asked to cite sources inline as `[S1]`, `[S2]`, … and specific moments as
//  `@ref(MM:SS)`. These verifiers drop any citation whose number is out of range and any `@ref`
//  outside the meeting timeline, so the model can never invent a citation or a play-badge (the
//  recall "no invented citations" / No-Fake-State invariants). Cheap manual scans — no regex —
//  ported character-for-character over Unicode scalars to match the Rust `Vec<char>` iteration.
//
import Foundation

extension Recall {
    /// Remove `[S<n>]` markers whose `n` is not a valid 1-based source index; keep valid ones
    /// (normalized to uppercase `S`) for the UI to render as citation chips
    /// (← `verify_source_citations`).
    public static func verifySourceCitations(_ answer: String, sourceCount: Int) -> String {
        let chars = scalars(answer)
        let len = chars.count
        var out = String.UnicodeScalarView()
        var i = 0

        while i < len {
            // Match the pattern `[` `S`/`s` <digits> `]`.
            if chars[i] == "[", i + 1 < len, chars[i + 1] == "S" || chars[i + 1] == "s" {
                let digitsStart = i + 2
                var j = digitsStart
                while j < len, isASCIIDigit(chars[j]) {
                    j += 1
                }
                if j > digitsStart, j < len, chars[j] == "]" {
                    let numberString = string(fromScalars: chars[digitsStart..<j])
                    let number = Int(numberString) ?? 0
                    if number >= 1, number <= sourceCount {
                        out.append(contentsOf: "[S\(number)]".unicodeScalars)
                    }
                    // Invalid citation → dropped entirely.
                    i = j + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }

        return String(out)
    }

    /// Parse a `MM:SS` / `H:MM:SS` / `HH:MM:SS` label into seconds. Returns `nil` for anything
    /// malformed or with out-of-range minute/second fields (← `parse_timestamp_label`).
    public static func parseTimestampLabel(_ label: String) -> Int? {
        let parts = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)

        func field(_ part: Substring) -> Int? {
            // Rust `u32::from_str` after `trim()`: non-negative integer only.
            guard let value = UInt32(part.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return Int(value)
        }

        switch parts.count {
        case 2:
            guard let minutes = field(parts[0]), let seconds = field(parts[1]) else { return nil }
            return seconds < 60 ? minutes * 60 + seconds : nil
        case 3:
            guard let hours = field(parts[0]),
                  let minutes = field(parts[1]),
                  let seconds = field(parts[2])
            else { return nil }
            return (minutes < 60 && seconds < 60) ? hours * 3600 + minutes * 60 + seconds : nil
        default:
            return nil
        }
    }

    /// Verify inline `@ref(MM:SS)` markers against a meeting's timeline (← `filter_ref_timestamps`).
    /// A kept marker stays as `@ref(MM:SS)` (the UI renders a play-badge); a rejected or
    /// unverifiable one is replaced by its bare label text (readable, not a badge — No-Fake-State).
    ///
    /// `maxSeconds != nil` keeps markers at or before it (+2s tolerance) — meeting-scoped, one
    /// timeline. `nil` strips ALL `@ref` markers — global, where a bare `MM:SS` is ambiguous.
    public static func filterRefTimestamps(_ answer: String, maxSeconds: Int?) -> String {
        let chars = scalars(answer)
        let len = chars.count
        var out = String.UnicodeScalarView()
        var i = 0

        while i < len {
            if chars[i] == "@", matchesAt(chars, at: i, needle: "@ref(") {
                let innerStart = i + 5
                var j = innerStart
                while j < len, chars[j] != ")" {
                    j += 1
                }
                if j < len, chars[j] == ")" {
                    let label = string(fromScalars: chars[innerStart..<j])
                    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let keep: Bool
                    if let seconds = parseTimestampLabel(label), let maxSeconds {
                        keep = seconds <= maxSeconds + 2
                    } else {
                        keep = false
                    }
                    if keep {
                        out.append(contentsOf: "@ref(\(trimmedLabel))".unicodeScalars)
                    } else {
                        // Rejected / unverifiable / global — keep the readable label, drop the marker.
                        out.append(contentsOf: trimmedLabel.unicodeScalars)
                    }
                    i = j + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }

        return String(out)
    }

    /// Whether `needle`'s scalars appear at `at` in `chars` (← `matches_at`).
    private static func matchesAt(_ chars: [Unicode.Scalar], at: Int, needle: String) -> Bool {
        for (offset, expected) in needle.unicodeScalars.enumerated() {
            let index = at + offset
            guard index < chars.count, chars[index] == expected else {
                return false
            }
        }
        return true
    }
}
