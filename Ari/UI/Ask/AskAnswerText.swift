//
//  AskAnswerText.swift — renders a reconciled assistant answer (docs/plans/ari-ask-ui.md §7/§8):
//  the answer is first split into display lines (`AskAnswerLayout` — paragraphs, `- `/`1. ` list
//  items with hanging markers, `#` headings, blank-line paragraph gaps) so the model's block
//  structure survives; within each line, plain-text runs flow as wrapping, lightly-markdown-styled
//  words; `[S<n>]` markers become
//  tappable citation chips (`AskSourcePopover`) resolved against THIS row's own `sources`, with a
//  literal `[S<n>]` fallback when `index` is out of range (defensive — the engine already
//  reconciles citations before the UI ever sees them, plan §0); `@ref(MM:SS)` markers render as
//  NON-interactive display-only pills (No-Fake-State — nothing seeks yet).
//
//  KNOWN SIMPLIFICATION: markdown emphasis (`**bold**`/`*italic*`) is parsed per TEXT SEGMENT
//  (the tokenizer's `.text` runs), not across the whole answer — an emphasis span that straddles a
//  citation/timestamp marker won't carry across it. Acceptable for the terse, mostly-plain-prose
//  answers this surface renders; `MarginaliaMarkdownView`'s sentinel technique is the fuller
//  approach but is scoped to actual markdown documents (series ledgers), not chat answers.
//
import AriKit
import AriViewModels
import SwiftUI

struct AskAnswerText: View {
    let text: String
    let sources: [RecallSource]
    let onOpenMeeting: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lines = AskAnswerLayout.lines(text)
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
                    .padding(.top, line.startsParagraph ? MarginaliaSpacing.xs.value : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ line: AskAnswerLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MarginaliaSpacing.xs.value) {
            switch line.marker {
            case .bullet:
                Text("•").marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            case let .number(label):
                Text(label).marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            case nil:
                EmptyView()
            }
            MarginaliaFlowLayout(spacing: 3, lineSpacing: MarginaliaSpacing.xs.value) {
                ForEach(Array(flowItems(for: line).enumerated()), id: \.offset) { _, item in
                    flowItemView(item, heading: line.isHeading)
                }
            }
        }
    }

    private enum FlowItem {
        case word(AttributedString)
        case citation(index: Int)
        case timestamp(String)
    }

    private func flowItems(for line: AskAnswerLine) -> [FlowItem] {
        line.segments.flatMap { segment -> [FlowItem] in
            switch segment {
            case let .text(raw):
                words(in: raw)
            case let .citation(index):
                [.citation(index: index)]
            case let .timestamp(value):
                [.timestamp(value)]
            }
        }
    }

    /// Whitespace-separated word tokens, emphasis-parsed per the plan's documented simplification
    /// above (mirrors `MarginaliaMarkdownView`'s per-token approach, minus the cross-marker
    /// sentinel machinery this surface doesn't need).
    private func words(in raw: String) -> [FlowItem] {
        let attributed = attributedInline(raw)
        var items: [FlowItem] = []
        var wordStart: AttributedString.Index?
        var index = attributed.startIndex

        func flush(_ end: AttributedString.Index) {
            if let start = wordStart {
                items.append(.word(AttributedString(attributed[start ..< end])))
                wordStart = nil
            }
        }

        while index < attributed.endIndex {
            if attributed.characters[index].isWhitespace {
                flush(index)
            } else if wordStart == nil {
                wordStart = index
            }
            index = attributed.index(afterCharacter: index)
        }
        flush(attributed.endIndex)
        return items
    }

    private func attributedInline(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }

    @ViewBuilder
    private func flowItemView(_ item: FlowItem, heading: Bool) -> some View {
        switch item {
        case let .word(attributed):
            Text(attributed).marginaliaTextStyle(heading ? .headline : .body, in: scheme)

        case let .citation(index):
            if index >= 1, index <= sources.count {
                AskSourcePopover(index: index, source: sources[index - 1], onOpenMeeting: onOpenMeeting)
            } else {
                // Defensive literal fallback (plan §7/§10 test 14) — the engine should never hand
                // back an unreconciled index, but a stale/out-of-range one renders as inert plain
                // text rather than crashing or silently dropping the marker.
                Text("[S\(index)]").marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            }

        case let .timestamp(value):
            // Non-interactive, display-only (No-Fake-State — it does nothing yet, plan §7).
            Text(value)
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                .padding(.horizontal, MarginaliaSpacing.xs.value)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                        .fill(Color.marginalia(.elevated, in: scheme))
                }
        }
    }
}
