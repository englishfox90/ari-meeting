//
//  MarginaliaMarkdownView.swift — the SwiftUI renderer for parsed Marginalia markdown blocks
//  (parser + block model live in MarginaliaMarkdown.swift). Headings ride the Bricolage ramp,
//  lists get styled rows, tables render flat + hairline-bordered, and inline citation markers
//  become tappable play chips when a handler is supplied.
//
//  Two citation flavors (see `InlineCitation`): an `[MM:SS]`/`@ref(...)` audio moment seeks THIS
//  document's player via `onSeek`; a series ledger's `@mref(m<index>@TS)` opens the referenced
//  member meeting via `onOpenMeetingMoment`. A citation with no matching handler (or a stale
//  out-of-range member index) renders as inert muted timecode text, never a dead "play" affordance
//  (No-Fake-State).
//
import SwiftUI

/// Renders a markdown document as Marginalia-styled blocks (headings on the Bricolage ramp,
/// styled lists, and a flat hairline-bordered table), instead of one flattened inline string.
public struct MarginaliaMarkdownView: View {
    private let blocks: [MarginaliaMarkdownBlock]
    /// Seeks THIS document's audio to a `[MM:SS]`/`@ref(...)` moment. `nil` when no audio resolves.
    private let onSeek: ((Double) -> Void)?
    /// Opens a series ledger's cross-meeting `@mref(m<index>@TS)` citation — the 1-based member
    /// index plus recording-relative seconds. `nil` outside a series ledger context.
    private let onOpenMeetingMoment: ((_ memberIndex: Int, _ seconds: Double) -> Void)?
    /// How many member meetings the `@mref` indices may address. When set, an index outside
    /// `1...count` renders inert (a stale link, never a fabricated jump). `nil` = don't range-check.
    private let meetingMomentCount: Int?
    @Environment(\.colorScheme) private var scheme

    public init(
        markdown: String,
        onSeek: ((Double) -> Void)? = nil,
        onOpenMeetingMoment: ((_ memberIndex: Int, _ seconds: Double) -> Void)? = nil,
        meetingMomentCount: Int? = nil
    ) {
        blocks = MarginaliaMarkdown.parse(markdown)
        self.onSeek = onSeek
        self.onOpenMeetingMoment = onOpenMeetingMoment
        self.meetingMomentCount = meetingMomentCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarginaliaMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            // title2 (19pt) for h1/h2, headline (17pt) for h3+ — both ≥17pt, so both render in
            // Bricolage per the ramp (MarginaliaRules.bricolageMinSizePt).
            Text(text)
                .marginaliaTextStyle(level <= 2 ? .title2 : .headline, in: scheme, ink: .inkHeading)
                .padding(.top, MarginaliaSpacing.sm.value)

        case let .paragraph(text):
            richText(text)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    listRow(marker: "\(offset + 1).", text: item)
                }
            }

        case let .table(header, rows):
            tableView(header: header, rows: rows)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MarginaliaSpacing.sm.value) {
            Text(marker)
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                .frame(minWidth: MarginaliaSpacing.md.value, alignment: .trailing)
            richText(text)
        }
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        return Grid(
            alignment: .leading,
            horizontalSpacing: MarginaliaSpacing.md.value,
            verticalSpacing: MarginaliaSpacing.sm.value
        ) {
            GridRow {
                ForEach(0 ..< columnCount, id: \.self) { column in
                    // Subheadline (not the uppercased `.caption` eyebrow) and inline-parsed, so a
                    // markdown header cell like `**Owner**` reads as "Owner", not "**OWNER**".
                    Text(attributedInline(column < header.count ? header[column] : ""))
                        .marginaliaTextStyle(.subheadline, in: scheme, ink: .inkSecondary)
                }
            }
            Divider().overlay(Color.marginalia(.hairline, in: scheme)).gridCellColumns(columnCount)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0 ..< columnCount, id: \.self) { column in
                        tableCell(column < row.count ? row[column] : "")
                    }
                }
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .background(
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        )
    }

    /// Body text for a paragraph or list item. When a handler is present and the text carries
    /// citation markers, it flows as tappable chips interleaved with the words (emphasis
    /// preserved); otherwise it's a single wrapping `Text` — the better typography when there's
    /// nothing to make interactive.
    @ViewBuilder
    private func richText(_ raw: String) -> some View {
        if hasInteractiveHandler, MarginaliaMarkdown.hasCitation(raw) {
            inlineFlow(raw)
        } else {
            Text(attributedInline(raw))
                .marginaliaTextStyle(.body, in: scheme)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A table body cell. A citation-bearing cell flows into chips (and claims the row's flexible
    /// width, so it becomes the wide column); a plain cell sizes to its content so label columns
    /// stay narrow.
    @ViewBuilder
    private func tableCell(_ raw: String) -> some View {
        if hasInteractiveHandler, MarginaliaMarkdown.hasCitation(raw) {
            inlineFlow(raw)
        } else {
            Text(attributedInline(raw))
                .marginaliaTextStyle(.body, in: scheme)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasInteractiveHandler: Bool {
        onSeek != nil || onOpenMeetingMoment != nil
    }

    /// A sentinel char standing in for a citation while the FULL line is parsed for emphasis, so
    /// `*italic*` / `**bold**` that straddles a citation is honored across it (parsing each text
    /// span in isolation would leave the run's `*`/`**` delimiters unbalanced and leak them as
    /// literal asterisks). Object Replacement Character — never appears in real ledger prose.
    private static let citationSentinel: Character = "\u{FFFC}"

    /// The tappable-chip flow: words as `Text`, citations as accent play badges (or inert muted
    /// timecode when their handler is absent / the member index is stale).
    private func inlineFlow(_ raw: String) -> some View {
        let spans = MarginaliaMarkdown.inlineSpans(raw)
        // Rebuild the line with each citation swapped for the sentinel, parse emphasis over the
        // whole thing, then split the attributed result back apart at the sentinels — pairing each
        // in order with its citation (index preserved, unlike `displayText`).
        let sentinel = String(Self.citationSentinel)
        let merged = spans.map { span -> String in
            if case let .text(text) = span {
                return text
            }
            return sentinel
        }.joined()
        let citations = spans.compactMap { span -> InlineCitation? in
            if case let .citation(citation) = span {
                return citation
            }
            return nil
        }
        let items = flowItems(from: attributedInline(merged), citations: citations)
        return MarginaliaFlowLayout(spacing: 3, lineSpacing: MarginaliaSpacing.xs.value) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                flowItemView(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func flowItemView(_ item: FlowItem) -> some View {
        switch item {
        case let .word(attributed):
            Text(attributed).marginaliaTextStyle(.body, in: scheme)

        case let .audio(seconds, label):
            if let onSeek {
                MarginaliaBadge(label, style: .accent, symbol: "play.fill", scheme: scheme) {
                    onSeek(seconds)
                }
            } else {
                inertMoment(label)
            }

        case let .meeting(index, seconds, label):
            if let onOpenMeetingMoment, isResolvableMember(index) {
                MarginaliaBadge(label, style: .accent, symbol: "play.fill", scheme: scheme) {
                    onOpenMeetingMoment(index, seconds)
                }
            } else {
                inertMoment(label)
            }
        }
    }

    /// A citation whose jump can't be honored — shown as muted timecode text, never a dead badge.
    private func inertMoment(_ label: String) -> some View {
        Text(label).marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
    }

    private func isResolvableMember(_ index: Int) -> Bool {
        guard let meetingMomentCount else { return true }
        return index >= 1 && index <= meetingMomentCount
    }

    /// Walks the emphasis-parsed line, emitting whitespace-separated word tokens (attributes
    /// preserved) between sentinels and one chip item per sentinel — consumed in order from
    /// `citations`. Splitting on the sentinel here (not on the raw markers) is what lets emphasis
    /// carry across a citation. Spacing between tokens is the flow layout's job, so trailing
    /// whitespace is dropped.
    private func flowItems(from attributed: AttributedString, citations: [InlineCitation]) -> [FlowItem] {
        var items: [FlowItem] = []
        var citationIndex = 0
        var wordStart: AttributedString.Index?
        var index = attributed.startIndex

        func flushWord(_ end: AttributedString.Index) {
            if let start = wordStart {
                items.append(.word(AttributedString(attributed[start ..< end])))
                wordStart = nil
            }
        }

        while index < attributed.endIndex {
            let character = attributed.characters[index]
            if character == Self.citationSentinel {
                flushWord(index)
                if citationIndex < citations.count {
                    switch citations[citationIndex] {
                    case let .audio(seconds, label):
                        items.append(.audio(seconds: seconds, label: label))
                    case let .meeting(memberIndex, seconds, label):
                        items.append(.meeting(index: memberIndex, seconds: seconds, label: label))
                    }
                    citationIndex += 1
                }
            } else if character.isWhitespace {
                flushWord(index)
            } else if wordStart == nil {
                wordStart = index
            }
            index = attributed.index(afterCharacter: index)
        }
        flushWord(attributed.endIndex)
        return items
    }

    /// Inline-emphasis `AttributedString` with citation markers normalized for display; falls
    /// back to plain text on parse failure.
    private func attributedInline(_ raw: String) -> AttributedString {
        let normalized = MarginaliaMarkdown.displayText(raw)
        return (try? AttributedString(
            markdown: normalized,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(normalized)
    }
}

/// One piece of an inline-flowed line: a word (with emphasis), an audio moment, or a cross-meeting
/// moment.
private enum FlowItem {
    case word(AttributedString)
    case audio(seconds: Double, label: String)
    case meeting(index: Int, seconds: Double, label: String)
}
