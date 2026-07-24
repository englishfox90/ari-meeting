//
//  SummaryEditingTests.swift — acceptance tests for `SummaryEditing`'s context-threaded
//  transforms (`docs/plans/native-text-formatting.md` §9, N15-N16).
//
#if os(macOS)
    import AppKit
#endif
import SwiftUI
import Testing
@testable import AriKit

@Suite("SummaryEditing — context-threaded toolbar transforms")
struct SummaryEditingTests {
    #if os(macOS)
        private func platformBoldBodyFont() -> Font {
            let nsBold = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 14, weight: .regular), toHaveTrait: .boldFontMask
            )
            return Font(nsBold)
        }

        private var fontContext: Font.Context {
            EnvironmentValues().fontResolutionContext
        }

        private func fullSelection(of text: AttributedString) -> AttributedTextSelection {
            AttributedTextSelection(range: text.startIndex ..< text.endIndex)
        }

        // MARK: - N15

        @Test("toggling bold on a natively-bolded run turns it off, rather than double-applying")
        func toggleBoldOnNativelyBoldedRunTurnsItOff() {
            // Pin the recovery this depends on directly first.
            let emphasis = SummaryCanonicalFont.emphasis(
                of: platformBoldBodyFont(), for: .paragraph, context: fontContext
            )
            #expect(emphasis == (true, false))

            var text = AttributedString("Hello")
            text.summaryBlock = .paragraph
            text.font = platformBoldBodyFont()
            var selection = fullSelection(of: text)

            SummaryEditing.toggleBold(in: &text, selection: &selection, context: fontContext)

            let resultFont = text.runs.first?.font
            #expect(resultFont == SummaryFontVariant.base(for: .paragraph))
        }

        // MARK: - N16

        @Test("setBlockKind carries a natively-applied bold across the kind change")
        func setBlockKindCarriesNativelyAppliedEmphasis() {
            var text = AttributedString("Hello")
            text.summaryBlock = .paragraph
            text.font = platformBoldBodyFont()
            var selection = fullSelection(of: text)

            SummaryEditing.setBlockKind(
                .heading(level: 1), in: &text, selection: &selection, context: fontContext
            )

            let resultKind = text.runs.first?.summaryBlock
            let resultFont = text.runs.first?.font
            #expect(resultKind == .heading(level: 1))
            #expect(resultFont == SummaryFontVariant.bold(for: .heading(level: 1)))
        }
    #endif
}
