//
//  RichEditorSpike.swift — THROWAWAY Step-0 spike for docs/plans/rich-summary-editor.md.
//
//  Purpose: prove the macOS 26 rich-text mechanism the plan rests on, against the GA SDK:
//   • a custom paragraph-scoped block attribute (runBoundaries: .paragraph + inheritedByAddedText)
//   • an AttributedTextFormattingDefinition whose custom AttributedTextValueConstraint READS the
//     block kind and COERCES the font (the §2.4 / R1 mechanism)
//   • TextEditor(text: Binding<AttributedString>, selection:) rendered as an "invisible" editor
//     (canvas background, no field chrome) so edit mode looks like the read view.
//
//  Not merged, not shipped: entire file is #if DEBUG. Delete after the spike verdict is recorded.
//
#if DEBUG
    import AriKit
    import SwiftUI

    // MARK: - Block attribute (mirrors plan §2.1, throwaway names)

    enum SpikeBlockKind: Codable, Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case bulletItem
    }

    enum SpikeBlockAttribute: CodableAttributedStringKey {
        typealias Value = SpikeBlockKind
        static let name = "com.arivo.ari.spikeBlock"
        static let inheritedByAddedText = true
        static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
    }

    extension AttributeScopes {
        struct SpikeScope: AttributeScope {
            let spikeBlock: SpikeBlockAttribute
            let swiftUI: SwiftUIAttributes
        }

        var spike: SpikeScope.Type {
            SpikeScope.self
        }
    }

    extension AttributeDynamicLookup {
        subscript<T: AttributedStringKey>(
            dynamicMember keyPath: KeyPath<AttributeScopes.SpikeScope, T>
        ) -> T {
            self[T.self]
        }
    }

    // MARK: - The load-bearing mechanism: constraint reads block kind, coerces font (§2.4 / R1)

    struct SpikeFontConstraint: AttributedTextValueConstraint {
        typealias Scope = AttributeScopes.SpikeScope
        typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

        func constrain(_ container: inout Attributes) {
            // READ a sibling attribute (block kind) via the dynamic-member proxy...
            let kind = container.spikeBlock ?? .paragraph
            // ...and WRITE this constraint's own attribute (font) to the canonical value for that kind.
            switch kind {
            case let .heading(level):
                container.font = level <= 2 ? .title2.bold() : .headline
            case .bulletItem, .paragraph:
                container.font = .body
            }
        }
    }

    struct SpikeFormatting: AttributedTextFormattingDefinition {
        typealias Scope = AttributeScopes.SpikeScope
        var body: some AttributedTextFormattingDefinition<Scope> {
            SpikeFontConstraint()
        }
    }

    // MARK: - The spike view

    struct RichEditorSpike: View {
        @State private var text = RichEditorSpike.seed()
        @State private var selection = AttributedTextSelection()
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(spacing: 0) {
                // The "invisible" editor: same canvas, no chrome — proves edit ≈ read visually.
                TextEditor(text: $text, selection: $selection)
                    .attributedTextFormattingDefinition(SpikeFormatting())
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .padding(MarginaliaSpacing.lg.value)
                    .background(MarginaliaCanvasWash(scheme: scheme))
                    .frame(minWidth: 380)

                Divider()

                // Live run dump: what block kind + font each run actually carries after editing.
                // Watch this while typing / Cmd+B / pasting to see if the constraint fired.
                runDump
                    .frame(width: 320)
            }
            .frame(minWidth: 720, minHeight: 460)
        }

        private var runDump: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RUNS (\(text.runs.count))").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(text.runs.enumerated()), id: \.offset) { index, run in
                        let raw = String(text.characters[run.range])
                        let shown = raw
                            .replacingOccurrences(of: "\u{2028}", with: "⏎LS")
                            .replacingOccurrences(of: "\n", with: "⏎NL")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(index)] kind=\(describe(run.spikeBlock)) font=\(run.font != nil ? "set" : "—")")
                                .font(.system(.caption, design: .monospaced))
                            Text("\"\(shown)\"")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func describe(_ kind: SpikeBlockKind?) -> String {
            switch kind {
            case .none: "nil"
            case .paragraph: "para"
            case let .heading(level): "h\(level)"
            case .bulletItem: "bullet"
            }
        }

        /// Seed with one of each: heading, a paragraph with an internal U+2028 soft break (R4),
        /// a paragraph carrying a bold sub-run, and a bullet item — all block-stamped.
        private static func seed() -> AttributedString {
            func para(_ string: String, _ kind: SpikeBlockKind) -> AttributedString {
                var attributed = AttributedString(string)
                attributed.spikeBlock = kind
                return attributed
            }

            var doc = para("Spike Heading", .heading(level: 2))
            doc += AttributedString("\n")
            doc += para("First line\u{2028}soft-broken second line (one paragraph).", .paragraph)
            doc += AttributedString("\n")

            var boldPara = para("Regular then ", .paragraph)
            var bold = para("bold", .paragraph)
            bold.font = .body.bold()
            boldPara += bold
            boldPara += para(" then regular.", .paragraph)
            doc += boldPara
            doc += AttributedString("\n")

            doc += para("•\tFirst bullet", .bulletItem)
            return doc
        }
    }

    #Preview {
        RichEditorSpike()
    }
#endif
