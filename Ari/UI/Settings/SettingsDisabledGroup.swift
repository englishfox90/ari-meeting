//
//  SettingsDisabledGroup.swift — the honest-disabled treatment every Settings section uses for
//  a not-yet-ported control group (docs/plans/settings-ui.md §6, No-Fake-State).
//
//  Wraps content in `.disabled(true)` + a `MarginaliaBanner(.info)` rendering the VM's REAL
//  `Availability.disabled(reason:)` string — never hardcoded view copy standing in for real
//  state.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsDisabledGroup<Content: View>: View {
    let availability: Availability
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            if case let .disabled(reason) = availability {
                MarginaliaBanner(kind: .info, message: reason, scheme: scheme)
            }
            content()
        }
        .disabled(isDisabled)
    }

    private var isDisabled: Bool {
        if case .disabled = availability {
            return true
        }
        return false
    }
}
