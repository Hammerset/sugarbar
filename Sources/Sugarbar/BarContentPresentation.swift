import SwiftUI
import SugarbarCore

extension BarContent {
    /// The number (or LO/HI) to show. `nil` when a glyph stands in for it (warm-up).
    var text: String? {
        switch self {
        case .empty:
            return "—"
        case .warmingUp:
            return nil
        case let .live(value, _, _, outOfRange):
            return outOfRange?.label ?? formatMmolPerL(value)
        case let .stale(value, _, outOfRange):
            return outOfRange?.label ?? formatMmolPerL(value)
        }
    }

    var glyph: String? {
        switch self {
        case .warmingUp: "hourglass"
        case .empty, .live, .stale: nil
        }
    }

    var trendSymbol: String? {
        if case let .live(_, _, trend, _) = self { return trend.symbolName }
        return nil
    }

    /// Only a live reading is drawn in its band colour; everything else is greyed so a
    /// stale or absent value can never read as in-range.
    var tint: Color {
        switch self {
        case let .live(_, band, _, _): band.tint
        case .stale, .warmingUp, .empty: .secondary
        }
    }
}
