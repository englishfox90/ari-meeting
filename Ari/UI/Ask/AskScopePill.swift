//
//  AskScopePill.swift — the "This meeting / This series / All meetings" scope switcher
//  (docs/plans/ari-ask-ui.md §7/§8). Shown only when more than one scope is available; the
//  selected segment uses a SELECTION wash (`MarginaliaSegmentedControl`'s `.secondary` role),
//  never solid accent (Signal Rule — recording owns the one Signal per screen).
//
import AriKit
import AriViewModels
import SwiftUI

struct AskScopePill: View {
    @Bindable var viewModel: AskViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if viewModel.availableScopes.count > 1 {
            MarginaliaSegmentedControl(
                selection: selectionBinding,
                segments: viewModel.availableScopes.map { scope in
                    MarginaliaSegment(value: scope, title: Self.segmentLabel(for: scope))
                },
                scheme: scheme
            )
        }
    }

    /// Routes segment taps through `viewModel.setScope(_:)` (which cancels any in-flight ask and
    /// drops its half-streamed placeholder, plan §4) instead of assigning `scope` directly.
    private var selectionBinding: Binding<AskScope> {
        Binding(
            get: { viewModel.scope },
            set: { viewModel.setScope($0) }
        )
    }

    /// Generic segment copy (plan §7: "This meeting / This series / All meetings") — NOT the
    /// scope's own display `title` (which carries the specific meeting/series name, used
    /// elsewhere for the empty-state heading).
    private static func segmentLabel(for scope: AskScope) -> String {
        switch scope {
        case .global: "All meetings"
        case .series: "This series"
        case .meeting: "This meeting"
        }
    }
}
