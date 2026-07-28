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
//  Within a series ledger's "Open action items" section specifically (bullets and table cells),
//  a trailing status marker (`Status: (new)`, `**(done)**`, an isolated `Status` table cell, …)
//  is extracted (`MarginaliaLedgerActionItem`) and rendered as a `MarginaliaBadge` instead of
//  literal text — Decisions/Recurring themes/Per-person threads carry no such vocabulary and are
//  left untouched.
//
import SwiftUI

/// Renders a markdown document as Marginalia-styled blocks (headings on the Bricolage ramp,
/// styled lists, and a flat hairline-bordered table), instead of one flattened inline string.
public struct MarginaliaMarkdownView: View {
    private let blocks: [MarginaliaMarkdownBlock]
    /// Parallel to `blocks`: `true` for a block that falls under an "Open action items" heading
    /// (case-insensitively contains "action item"), so bullets/table cells there — and only
    /// there — get their status marker parsed into a badge instead of literal text.
    private let actionItemsSectionFlags: [Bool]
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
        let parsedBlocks = MarginaliaMarkdown.parse(markdown)
        blocks = parsedBlocks
        var inActionItems = false
        actionItemsSectionFlags = parsedBlocks.map { block in
            if case let .heading(_, text) = block {
                inActionItems = text.lowercased().contains("action item")
            }
            return inActionItems
        }
        self.onSeek = onSeek
        self.onOpenMeetingMoment = onOpenMeetingMoment
        self.meetingMomentCount = meetingMomentCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                blockView(block, isActionItemsSection: actionItemsSectionFlags[offset])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarginaliaMarkdownBlock, isActionItemsSection: Bool) -> some View {
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
                    listRow(marker: "•", text: item, isActionItemsSection: isActionItemsSection)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    listRow(marker: "\(offset + 1).", text: item, isActionItemsSection: isActionItemsSection)
                }
            }

        case let .table(header, rows):
            tableView(header: header, rows: rows, isActionItemsSection: isActionItemsSection)
        }
    }

    private func listRow(marker: String, text: String, isActionItemsSection: Bool) -> some View {
        let (body, status): (String, MarginaliaLedgerStatus?) = isActionItemsSection
            ? MarginaliaLedgerActionItem.extractStatus(from: text)
            : (text, nil)
        return HStack(alignment: .firstTextBaseline, spacing: MarginaliaSpacing.sm.value) {
            Text(marker)
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                .frame(minWidth: MarginaliaSpacing.md.value, alignment: .trailing)
            if let status {
                inlineFlow(body, trailingStatus: status)
            } else {
                richText(text)
            }
        }
    }

    private func tableView(header: [String], rows: [[String]], isActionItemsSection: Bool) -> some View {
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
                        tableCell(column < row.count ? row[column] : "", isActionItemsSection: isActionItemsSection)
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
    /// stay narrow. Within the action-items section, a cell's status marker (including a whole
    /// cell that IS just the marker — the dedicated `Status` column) becomes a badge.
    @ViewBuilder
    private func tableCell(_ raw: String, isActionItemsSection: Bool) -> some View {
        let (body, status): (String, MarginaliaLedgerStatus?) = isActionItemsSection
            ? MarginaliaLedgerActionItem.extractStatus(from: raw)
            : (raw, nil)
        if let status {
            inlineFlow(body, trailingStatus: status)
        } else if hasInteractiveHandler, MarginaliaMarkdown.hasCitation(raw) {
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
    /// timecode when their handler is absent / the member index is stale). `trailingStatus`, when
    /// set, appends a ledger status badge as one more flow item after every word/citation — used
    /// by action-item rows so the badge wraps naturally alongside the text instead of sitting on
    /// its own line.
    private func inlineFlow(_ raw: String, trailingStatus: MarginaliaLedgerStatus? = nil) -> some View {
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
        var items = flowItems(from: attributedInline(merged), citations: citations)
        if let trailingStatus {
            items.append(.status(trailingStatus))
        }
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

        case let .audio(seconds, label, trailingPunctuation):
            if let onSeek {
                citationChip(label: label, trailingPunctuation: trailingPunctuation) { onSeek(seconds) }
            } else {
                inertMoment(label + trailingPunctuation)
            }

        case let .meeting(index, seconds, label, trailingPunctuation):
            if let onOpenMeetingMoment, isResolvableMember(index) {
                citationChip(label: label, trailingPunctuation: trailingPunctuation) {
                    onOpenMeetingMoment(index, seconds)
                }
            } else {
                inertMoment(label + trailingPunctuation)
            }

        case let .status(status):
            statusBadge(status)
        }
    }

    /// A tappable citation chip with any immediately-trailing punctuation (a sentence-ending
    /// period, a comma before the next clause, …) glued on with NO gap — `MarginaliaFlowLayout`
    /// applies its fixed inter-item spacing between every flow item, which would otherwise float
    /// that punctuation away from the chip it belongs to (e.g. "▶ 07:06 ." instead of "▶ 07:06.").
    private func citationChip(
        label: String,
        trailingPunctuation: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            MarginaliaBadge(label, style: .accent, symbol: "play.fill", scheme: scheme, action: action)
            if !trailingPunctuation.isEmpty {
                Text(trailingPunctuation).marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            }
        }
    }

    /// A ledger action item's status badge (see `MarginaliaLedgerActionItem`/
    /// `MarginaliaLedgerStatus`). `dropped` renders visibly de-emphasized (reduced opacity) rather
    /// than as its own formal badge style, since it shares `.neutral`'s low-key appearance.
    @ViewBuilder
    private func statusBadge(_ status: MarginaliaLedgerStatus) -> some View {
        switch status {
        case .new:
            MarginaliaBadge(status.label, style: .info, scheme: scheme)
        case .stillOpen:
            MarginaliaBadge(status.label, style: .neutral, scheme: scheme)
        case .done:
            MarginaliaBadge(status.label, style: .success, scheme: scheme)
        case .dropped:
            MarginaliaBadge(status.label, style: .neutral, scheme: scheme).opacity(0.55)
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

    /// Splits a leading run of punctuation characters (`.`, `,`, `;`, `:`, `!`, `?`, closing
    /// brackets, …) off the front of `text`. Used to merge punctuation that immediately trails a
    /// citation sentinel into that citation's flow item, so `MarginaliaFlowLayout`'s fixed
    /// inter-item spacing never floats it away from the chip it follows. Pure — `package`-visible
    /// purely so it can be unit-tested directly without a SwiftUI environment.
    package nonisolated static func splitLeadingPunctuation(
        _ text: Substring
    ) -> (punctuation: Substring, rest: Substring) {
        let punctuation = text.prefix { $0.isPunctuation }
        return (punctuation, text[punctuation.endIndex...])
    }

    /// Walks the emphasis-parsed line, emitting whitespace-separated word tokens (attributes
    /// preserved) between sentinels and one chip item per sentinel — consumed in order from
    /// `citations`. Splitting on the sentinel here (not on the raw markers) is what lets emphasis
    /// carry across a citation. Spacing between tokens is the flow layout's job, so trailing
    /// whitespace is dropped. Any run of punctuation immediately following a sentinel (no
    /// intervening whitespace) is merged into that citation's item rather than becoming its own
    /// word token — see `splitLeadingPunctuation`.
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
                var next = attributed.index(afterCharacter: index)
                if citationIndex < citations.count {
                    let remainder = String(attributed.characters[next...])
                    let (punctuation, _) = Self.splitLeadingPunctuation(remainder[...])
                    let trailingPunctuation = String(punctuation)
                    for _ in 0 ..< trailingPunctuation.count {
                        next = attributed.index(afterCharacter: next)
                    }
                    switch citations[citationIndex] {
                    case let .audio(seconds, label):
                        items.append(.audio(seconds: seconds, label: label, trailingPunctuation: trailingPunctuation))
                    case let .meeting(memberIndex, seconds, label):
                        items.append(.meeting(
                            index: memberIndex,
                            seconds: seconds,
                            label: label,
                            trailingPunctuation: trailingPunctuation
                        ))
                    }
                    citationIndex += 1
                }
                index = next
                continue
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

/// One piece of an inline-flowed line: a word (with emphasis), an audio moment, a cross-meeting
/// moment, or a ledger status badge (each citation carries any immediately-trailing punctuation
/// merged in — see `MarginaliaMarkdownView.splitLeadingPunctuation`).
private enum FlowItem {
    case word(AttributedString)
    case audio(seconds: Double, label: String, trailingPunctuation: String)
    case meeting(index: Int, seconds: Double, label: String, trailingPunctuation: String)
    case status(MarginaliaLedgerStatus)
}
