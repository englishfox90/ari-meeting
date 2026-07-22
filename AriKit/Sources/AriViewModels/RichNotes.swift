//
//  RichNotes.swift — renders calendar-event notes that may contain raw HTML
//  (docs/plans/arikit-calendar-ui.md follow-on, 2026-07-22).
//
//  Google Calendar / Loom / Meet stuff HTML fragments into event descriptions
//  (`<div id="loom-description"><b>…</b><br><a href="…">…</a></div>` plus a plain-text tail
//  with bare URLs). Showing that verbatim is honest but unreadable. This helper parses it into
//  an `AttributedString` that keeps ONLY structure the ambient design system can express —
//  bold/italic as inline presentation intents (never explicit fonts, so Marginalia typography
//  stays in charge) and tappable links — and linkifies bare URLs in plain-text spans.
//
//  No-Fake-State note: this is presentation of real data, never synthesis — every character
//  shown comes from the event's own notes (entity-decoded), and unparseable input falls back
//  to the raw string untouched.
//
import Foundation
#if canImport(AppKit)
    import AppKit
#endif

public enum RichNotes {
    /// Heuristic: does this string carry HTML markup worth parsing? Matches common tags and
    /// entities; plain prose with a stray `<` won't trip it.
    public static func looksLikeHTML(_ raw: String) -> Bool {
        raw.range(
            of: #"<\s*/?\s*(a|b|i|u|em|strong|br|div|p|span|ul|ol|li|h[1-6])\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil || raw.range(
            of: #"&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);"#,
            options: .regularExpression
        ) != nil
    }

    /// Parse notes into a styled `AttributedString`. HTML input keeps bold/italic (as
    /// presentation intents) and links; plain input passes through. Bare URLs in either are
    /// made tappable. Must run on the main actor — the system HTML importer requires it.
    @MainActor
    public static func attributed(from raw: String) -> AttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString() }

        var result: AttributedString
        if looksLikeHTML(trimmed), let parsed = parseHTML(trimmed) {
            result = parsed
        } else {
            result = AttributedString(trimmed)
        }
        linkifyBareURLs(in: &result)
        return result
    }

    // MARK: - HTML path

    #if canImport(AppKit)
        @MainActor
        private static func parseHTML(_ html: String) -> AttributedString? {
            // Plain-text tails (the Google Meet block) use bare newlines, which HTML rendering
            // would collapse to spaces — promote them to <br> so real line structure survives.
            let normalized = html
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
            guard let data = normalized.data(using: .utf8),
                  let parsed = try? NSAttributedString(
                      data: data,
                      options: [
                          .documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue,
                      ],
                      documentAttributes: nil
                  )
            else { return nil }

            // Rebuild keeping only link + bold/italic (as intents). Everything else — WebKit's
            // default fonts, colors, paragraph styles — is dropped so the ambient Marginalia
            // text style governs.
            var rebuilt = AttributedString()
            parsed.enumerateAttributes(in: NSRange(location: 0, length: parsed.length)) { attrs, range, _ in
                var run = AttributedString(parsed.attributedSubstring(from: range).string)
                if let url = attrs[.link] as? URL {
                    run.link = url
                } else if let str = attrs[.link] as? String, let url = URL(string: str) {
                    run.link = url
                }
                if let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    var intent: InlinePresentationIntent = []
                    if traits.contains(.bold) { intent.insert(.stronglyEmphasized) }
                    if traits.contains(.italic) { intent.insert(.emphasized) }
                    if !intent.isEmpty { run.inlinePresentationIntent = intent }
                }
                rebuilt += run
            }
            // The importer appends a trailing newline to block content; trim edges.
            return trimmedEdges(rebuilt)
        }
    #else
        @MainActor
        private static func parseHTML(_: String) -> AttributedString? { nil }
    #endif

    private static func trimmedEdges(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        let text = String(result.characters)
        let leading = text.prefix(while: { $0.isNewline || $0 == " " }).count
        if leading > 0, leading <= text.count {
            let end = result.index(result.startIndex, offsetByCharacters: leading)
            result.removeSubrange(result.startIndex ..< end)
        }
        let trailingText = String(result.characters)
        let trailing = trailingText.reversed().prefix(while: { $0.isNewline || $0 == " " }).count
        if trailing > 0, trailing <= trailingText.count {
            let start = result.index(result.endIndex, offsetByCharacters: -trailing)
            result.removeSubrange(start ..< result.endIndex)
        }
        return result
    }

    // MARK: - Bare-URL linkification (plain spans only — existing links untouched)

    private static func linkifyBareURLs(in attributed: inout AttributedString) {
        let text = String(attributed.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return
        }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: attributed)
            else { continue }
            // Never re-link inside an anchor the HTML already carried.
            if attributed[range].runs.contains(where: { $0.link != nil }) { continue }
            attributed[range].link = url
        }
    }
}
