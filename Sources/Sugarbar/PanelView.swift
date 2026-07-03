import SwiftUI
import SugarbarCore
import SugarbarUI

struct PanelView: View {
    let model: BarViewModel
    var onOpenSettings: () -> Void = {}
    @State private var window: HistoryWindow = .fourHours
    @State private var selectedDate: Date?

    private var thresholds: Thresholds { model.thresholds }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chart
            rangePicker
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                headerValue
                if let symbol = model.content.trendSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(valueTint)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let latest = model.latest {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatAge(latest.age(at: context.date)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let state = stateLine {
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(stateIsWarning ? .orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var headerValue: some View {
        if let text = model.content.text {
            Text(text)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(valueTint)
        } else if let glyph = model.content.glyph {
            Image(systemName: glyph)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(valueTint)
        }
    }

    private var chart: some View {
        GlucoseHistoryChart(
            series: model.chartSeries(window: window),
            thresholds: thresholds,
            latest: model.latest,
            valueTint: valueTint,
            xDomain: xDomain,
            selectedDate: $selectedDate
        )
    }

    private var rangePicker: some View {
        Picker("Range", selection: $window) {
            ForEach(HistoryWindow.allCases) { window in
                Text("\(window.hours)h").tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not a medical device — for information only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
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

    private var xDomain: ClosedRange<Date> {
        let end = model.now
        return end.addingTimeInterval(-Double(window.hours) * 3600)...end
    }
}
