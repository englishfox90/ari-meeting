#if DEBUG
//
//  DesignGalleryButtonsView.swift — the button-role/size matrix and spacing/radii scales for
//  `DesignGalleryView` (DEBUG only — see that file's header for the split rationale).
//
import AriKit
import SwiftUI

/// Section 4: every `MarginaliaButtonRole` x `MarginaliaButtonSize` as real, live buttons —
/// press states must work, so these are genuine `Button`s, not static mockups. Neither
/// `MarginaliaButtonRole` nor `MarginaliaButtonSize` is `CaseIterable` (they're plain-data
/// enums, not a public enumeration surface), so the matrix is declared explicitly here.
struct DesignGalleryButtonsSection: View {
    let scheme: ColorScheme
    let glass: Bool

    private let roles: [(role: MarginaliaButtonRole, name: String)] = [
        (.primary, "Primary"),
        (.secondary, "Secondary"),
        (.quiet, "Quiet"),
        (.recording, "Recording"),
    ]

    private let sizes: [(size: MarginaliaButtonSize, name: String)] = [
        (.regular, "Regular"),
        (.large, "Large"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "BUTTONS")
            VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                ForEach(Array(sizes.enumerated()), id: \.offset) { _, sizeEntry in
                    sizeRow(sizeEntry.size, name: sizeEntry.name)
                }
            }
            .padding(MarginaliaSpacing.lg.value)
            .galleryComponentSurface(glass: glass, scheme: scheme)
        }
    }

    private func sizeRow(_ size: MarginaliaButtonSize, name: String) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text(name)
                .marginaliaTextStyle(.caption, in: scheme)
            HStack(spacing: MarginaliaSpacing.md.value) {
                ForEach(Array(roles.enumerated()), id: \.offset) { _, roleEntry in
                    Button(roleEntry.name) {}
                        .buttonStyle(.marginalia(roleEntry.role, size, in: scheme))
                }
            }
        }
    }
}

/// Section 5: the spacing scale (as labeled width bars) and the three radii (as labeled
/// rounded rects).
struct DesignGallerySpacingSection: View {
    let scheme: ColorScheme

    private let radii: [(radius: MarginaliaRadius, name: String)] = [
        (.control, "Control"),
        (.card, "Card"),
        (.dialog, "Dialog"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "SPACING & RADII")
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                ForEach(MarginaliaSpacing.allCases, id: \.self) { step in
                    spacingRow(step)
                }
            }
            HStack(spacing: MarginaliaSpacing.lg.value) {
                ForEach(Array(radii.enumerated()), id: \.offset) { _, entry in
                    radiusSample(entry.radius, name: entry.name)
                }
            }
        }
    }

    private func spacingRow(_ step: MarginaliaSpacing) -> some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Text("\(Int(step.value))pt")
                .marginaliaTextStyle(.timecode, in: scheme)
                .frame(width: 40, alignment: .leading)
            RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                .fill(Color.marginalia(.accent, in: scheme))
                .frame(width: step.value, height: 12)
        }
    }

    private func radiusSample(_ radius: MarginaliaRadius, name: String) -> some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            RoundedRectangle(cornerRadius: radius.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: radius.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                )
                .frame(width: 72, height: 48)
            Text("\(name) · \(Int(radius.value))pt")
                .marginaliaTextStyle(.timecode, in: scheme)
        }
    }
}
#endif
