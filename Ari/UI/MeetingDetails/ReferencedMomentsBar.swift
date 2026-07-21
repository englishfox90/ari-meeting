//
//  ReferencedMomentsBar.swift — a wrapping row of tappable citation chips parsed from the
//  summary. Each chip seeks the audio to that moment. Rendered only when there are real
//  markers (the caller omits it for an empty list — No-Fake-State).
//
import AriKit
import SwiftUI

struct ReferencedMomentsBar: View {
    let moments: [Double]
    let onSeek: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Referenced moments")
                .marginaliaTextStyle(.caption, in: scheme)
            MarginaliaFlowLayout(spacing: MarginaliaSpacing.sm.value) {
                ForEach(moments, id: \.self) { moment in
                    MarginaliaBadge(
                        MarginaliaTimecode.label(moment),
                        style: .accent,
                        symbol: "play.fill",
                        scheme: scheme
                    ) {
                        onSeek(moment)
                    }
                }
            }
        }
    }
}
