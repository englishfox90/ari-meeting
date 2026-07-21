//
//  ConsentSheet.swift — the consent-before-record gate (docs/plans/ari-recording-page.md §2.5,
//  §4.3, §7). Copy verbatim from BRAND.md §2.
//
//  Stock `.sheet` presentation — ZERO custom background. Liquid Glass v2: stock presentations
//  get the system's glass automatically; painting a custom material behind this content would
//  fight it. `confirmConsent()` is the ONLY edge into capture (structural invariant) — this
//  sheet's "Record" button is the sole caller.
//
import AriKit
import SwiftUI

struct ConsentSheet: View {
    let onRecord: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: MarginaliaSpacing.lg.value) {
            VStack(spacing: MarginaliaSpacing.sm.value) {
                Text("Record this meeting?")
                    .marginaliaTextStyle(.title2, in: scheme)
                    .multilineTextAlignment(.center)
                Text("Everyone on the call should know they're being recorded.")
                    .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: MarginaliaSpacing.md.value) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.marginalia(.quiet, .large, in: scheme))

                Button("Record") {
                    onRecord()
                    dismiss()
                }
                .buttonStyle(.marginalia(.recording, .large, in: scheme))
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(minWidth: 360)
    }
}
