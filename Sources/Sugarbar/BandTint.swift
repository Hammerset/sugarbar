import SwiftUI
import SugarbarCore

extension Band {
    var tint: Color {
        switch self {
        case .urgentLow: .red
        case .low: .orange
        case .inRange: .green
        // Pure yellow washes out on a light menu bar; amber stays legible on both.
        case .high: Color(red: 0.82, green: 0.6, blue: 0.0)
        case .urgentHigh: .red
        }
    }
}
