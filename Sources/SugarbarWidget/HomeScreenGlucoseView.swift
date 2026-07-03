import AppIntents
import SugarbarCore
import SugarbarUI
import SwiftUI

/// systemSmall / systemMedium: full colour, matching the menu bar and iOS reading
/// screen — only a `.live` reading is ever drawn in its band colour.
struct HomeScreenGlucoseView: View {
    let entry: GlucoseEntry
    let showsHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            valueRow
            ageLine
            if showsHistory {
                GlucoseSparkline(history: entry.history, thresholds: entry.thresholds)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
        .overlay(alignment: .topTrailing) {
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button(intent: RefreshGlucoseIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let text = entry.content.text {
                Text(text)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.content.tint)
            } else if let glyph = entry.content.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(entry.content.tint)
            }
            if let symbol = entry.content.trendSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(entry.content.tint)
            }
        }
    }

    @ViewBuilder
    private var ageLine: some View {
        switch entry.content {
        case let .warmingUp(remaining):
            Text("Warming up · \(max(1, Int(ceil(remaining / 60))))m")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .empty:
            Text("No data")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .live, .stale:
            if let timestamp = entry.latest?.timestamp {
                Text(timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
