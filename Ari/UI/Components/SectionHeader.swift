//
//  SectionHeader.swift — uppercase-caption section header (plan §2.2 Components).
//
import AriKit
import SwiftUI

struct SectionHeader: View {
    let title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(title)
            .marginaliaTextStyle(.caption, in: scheme)
            .padding(.horizontal, MarginaliaSpacing.md.value)
    }
}
