//
//  CardRow.swift — shared list-row primitive: title + metadata + trailing chevron
//  (plan §2.2 Components).
//
import AriKit
import SwiftUI

struct CardRow: View {
    let title: String
    let metadata: String?
    @Environment(\.colorScheme) private var scheme

    init(title: String, metadata: String? = nil) {
        self.title = title
        self.metadata = metadata
    }

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(title)
                    .marginaliaTextStyle(.body, in: scheme)
                    .lineLimit(1)
                if let metadata {
                    Text(metadata)
                        .marginaliaTextStyle(.callout, in: scheme)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
        }
        .padding(.vertical, MarginaliaSpacing.sm.value)
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }
}
