//
//  CardListScaffold.swift — shared list-screen scaffold: `StateContainer` → `List(.inset)` →
//  `NavigationLink(value:)` → `CardRow`, canvas background + navigation title (plan §2.2 Wave 2;
//  extracted from the identical bodies of `MeetingsListView` / `PeopleListView` / `SeriesListView`).
//
import AriKit
import AriViewModels
import SwiftUI

struct CardListScaffold<Item: Identifiable & Sendable, Destination: Hashable>: View {
    let state: LoadState<[Item]>
    let emptyTitle: String
    let emptyMessage: String?
    let navigationTitle: String
    let destination: (Item) -> Destination
    let rowTitle: (Item) -> String
    let rowMetadata: (Item) -> String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        StateContainer(
            state: state,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage
        ) { items in
            List(items) { item in
                NavigationLink(value: destination(item)) {
                    CardRow(title: rowTitle(item), metadata: rowMetadata(item))
                }
            }
            .listStyle(.inset)
            // Hide the List's own opaque backdrop so the ambient canvas wash shows through
            // (rows keep their stock appearance; only the page ground changes).
            .scrollContentBackground(.hidden)
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle(navigationTitle)
    }
}
