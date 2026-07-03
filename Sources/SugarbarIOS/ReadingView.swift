import SwiftUI
import SugarbarCore
import SugarbarUI

struct ReadingView: View {
    let model: GlucoseViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            valueDisplay

            if let latest = model.latest {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatAge(latest.age(at: context.date)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let stateLine {
                Text(stateLine)
                    .font(.subheadline)
                    .foregroundStyle(stateIsWarning ? .orange : .secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Sign Out", role: .destructive) {
                model.signOut()
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var valueDisplay: some View {
        HStack(alignment: .center, spacing: 12) {
            if let text = model.content.text {
                Text(text)
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueTint)
            } else if let glyph = model.content.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(valueTint)
            }
            if let symbol = model.content.trendSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(valueTint)
            }
        }
    }

    private var valueTint: Color { model.content.tint }

    private var stateIsWarning: Bool {
        if model.statusMessage != nil { return true }
        if case .stale = model.content { return true }
        return false
    }

    private var stateLine: String? {
        if let message = model.statusMessage { return message }
        switch model.content {
        case let .warmingUp(remaining):
            let minutes = max(1, Int(ceil(remaining / 60)))
            return "Sensor warming up — ready in \(minutes) min"
        case .stale:
            return "No Recent Data"
        case .empty:
            return "Waiting for data"
        case let .live(_, _, _, outOfRange):
            switch outOfRange {
            case .low: return "Below sensor range"
            case .high: return "Above sensor range"
            case nil: return nil
            }
        }
    }
}
