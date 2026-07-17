//
//  PlaceholderView.swift
//  ari-notch
//
//  Trivial placeholder content mounted inside the DynamicNotch panel so the
//  scaffold renders *something* end-to-end. The real recording HUD (the UC2
//  "REC" signal, elapsed timer, transcript line, meeting title) is WS-C's job
//  and replaces this view at the extension point marked in `main.swift`.
//
//  DESIGN NOTE: this view is intentionally NEUTRAL. It hardcodes no brand
//  tokens — the Arivo Amber REC signal belongs to WS-C. Keep it token-free so
//  there is nothing here to drift from DESIGN.json.
//

import SwiftUI

struct PlaceholderView: View {
    /// Observed so the scaffold visibly reacts to inbound messages during
    /// bring-up. WS-C will design the real bindings.
    var model: NotchModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .imageScale(.medium)
            Text("Ari Notch")
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
            if model.isRecording {
                // Neutral status text only — NO amber signal dot here (WS-C owns that).
                Text(model.isPaused ? "paused" : "recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // WS-C: replace this whole view with RecordingHUDView(model:).
    }
}
