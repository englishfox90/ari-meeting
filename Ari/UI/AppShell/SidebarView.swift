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
        .navigationTitle("Ari")
    }
}
