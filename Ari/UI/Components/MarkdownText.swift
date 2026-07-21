//
//  MarkdownText.swift — `Text(AttributedString(markdown:))` with an honest fallback to
//  plain text on parse failure (plan §2.2 Components; markdown fidelity is a known,
//  accepted gap vs. BlockNote — plan risks).
//
import AriKit
import SwiftUI

struct MarkdownText: View {
    let markdown: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(attributedString)
            .marginaliaTextStyle(.body, in: scheme)
            .textSelection(.enabled)
    }

    private var attributedString: AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(markdown)
    }
}
