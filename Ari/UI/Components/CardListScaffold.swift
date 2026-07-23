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
    /// Optional per-row right-click menu (e.g. Rename / Delete). `nil` (the default) leaves rows
    /// with no context menu — the People/Series screens use the scaffold without one.
    let rowMenu: ((Item) -> AnyView)?

    @Environment(\.colorScheme) private var scheme

    /// Explicit init so `rowMenu` can default to nil: an optional stored property's `= nil` is
    /// stripped by the formatter (redundantNilInit), which would delete the memberwise-init
    /// default and force every call site (People/Series) to pass `rowMenu`. A parameter default
    /// survives the formatter.
    init(
        state: LoadState<[Item]>,
        emptyTitle: String,
        emptyMessage: String?,
        navigationTitle: String,
        destination: @escaping (Item) -> Destination,
        rowTitle: @escaping (Item) -> String,
        rowMetadata: @escaping (Item) -> String?,
        rowMenu: ((Item) -> AnyView)? = nil
    ) {
        self.state = state
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.navigationTitle = navigationTitle
        self.destination = destination
        self.rowTitle = rowTitle
        self.rowMetadata = rowMetadata
        self.rowMenu = rowMenu
    }

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
                .modifier(RowContextMenu(menu: rowMenu.map { $0(item) }))
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

/// Attaches a `.contextMenu` only when the caller supplied one — with no menu, the row is left
/// exactly as it was (no empty menu, no behavior change for the People/Series screens).
private struct RowContextMenu: ViewModifier {
    let menu: AnyView?

    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu { menu }
        } else {
            content
        }
    }
}
