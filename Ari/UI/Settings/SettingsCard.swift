//
//  SettingsCard.swift — the canonical Settings card recipe (docs/plans/settings-ui.md §6).
//
//  Content layer stays paper (`.elevated` fill + hairline stroke), never glass — glass is
//  chrome-only (the toolbar's section switcher). Mirrors `AboutView`'s `pillarCard`/
//  `attribution` card recipe so Settings reads as one family with the rest of the app.
//
import AriKit
import SwiftUI

/// A titled card wrapping arbitrary row content — the one card shape every Settings section
/// composes with.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            if let title {
                Text(title)
                    .marginaliaTextStyle(.subheadline, in: scheme)
            }
            content()
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                }
        }
    }
}
