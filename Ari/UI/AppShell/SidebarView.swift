//
//  SidebarView.swift — sidebar column: List(selection:) of sections, SF Symbol per section
//  (plan §2.2 AppShell, §6 Navigation model). SF Symbols only — never emoji.
//
import AriKit
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List(SidebarSection.built, selection: $selection) { section in
            Label(section.title, systemImage: section.symbolName)
                .marginaliaTextStyle(.body, in: scheme)
        }
        .safeAreaInset(edge: .top, spacing: 0) { wordmark }
        .navigationTitle("")
    }

    /// The wordmark: the Dictation mark + "Ari Meetings" (composed in SwiftUI rather than the
    /// wordmark SVG, whose `<text>` element Xcode can't render). Top padding clears the floating
    /// traffic lights under the frameless/unified title bar.
    private var wordmark: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 30)
                .foregroundStyle(Color.marginalia(.accent, in: scheme))
            Text("Ari Meetings")
                .marginaliaTextStyle(.headline, in: scheme)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.xxl.value)
        .padding(.bottom, MarginaliaSpacing.sm.value)
    }
}
