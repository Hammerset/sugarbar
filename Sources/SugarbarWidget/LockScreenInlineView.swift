import SugarbarCore
import SwiftUI

/// accessoryInline has room for one line of text plus a glyph — no gauge fits, so
/// urgency is conveyed by swapping the glyph itself rather than by colour.
struct LockScreenInlineView: View {
    let entry: GlucoseEntry

    var body: some View {
        Label(text, systemImage: glyph)
    }

    private var text: String {
        switch entry.content {
        case .warmingUp: "Warming up"
        case .empty: "No data"
        case .live, .stale: entry.content.text ?? "—"
        }
    }

    private var glyph: String {
        switch entry.content {
        case .warmingUp: "hourglass"
        case .empty: "drop"
        case let .live(_, band, _, _): band.isUrgent ? "exclamationmark.triangle.fill" : "drop.fill"
        case let .stale(_, band, _): band.isUrgent ? "exclamationmark.triangle.fill" : "drop.fill"
        }
    }
}
