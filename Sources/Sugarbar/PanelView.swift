import Charts
import SwiftUI
import SugarbarCore

struct PanelView: View {
    let model: BarViewModel
    var onOpenSettings: () -> Void = {}
    @State private var window: HistoryWindow = .fourHours

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
            Text(model.displayValue)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(valueTint)
            if let symbol = model.trendSymbolName {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(valueTint)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let timestamp = model.latest?.timestamp {
                    HStack(spacing: 3) {
                        Text(timestamp, style: .relative)
                        Text("ago")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if let state = stateLine {
                    Text(state)
                        .font(.caption)
                        .foregroundStyle(model.isStale ? .orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let series = model.chartSeries(window: window)
        if series.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
                Text("No recent history")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 180)
        } else {
            Chart {
                RectangleMark(
                    yStart: .value("In-range low", thresholds.low),
                    yEnd: .value("In-range high", thresholds.high)
                )
                .foregroundStyle(.green.opacity(0.12))

                ForEach(thresholdLines, id: \.value) { line in
                    RuleMark(y: .value("Threshold", line.value))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(line.color.opacity(0.4))
                }

                ForEach(series, id: \.timestamp) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value("mmol/L", reading.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.primary)
                }

                if let latest = model.latest {
                    PointMark(
                        x: .value("Time", latest.timestamp),
                        y: .value("mmol/L", latest.value)
                    )
                    .foregroundStyle(valueTint)
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain(for: series))
            .frame(height: 180)
        }
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
                Button("Settings…", action: onOpenSettings)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var valueTint: Color {
        guard !model.isStale, let band = model.band else { return .secondary }
        return band.tint
    }

    private var stateLine: String? {
        if let message = model.statusMessage { return message }
        if model.latest == nil { return "Waiting for data" }
        if model.isStale { return "No Recent Data" }
        return nil
    }

    private var thresholdLines: [(value: Double, color: Color)] {
        [
            (thresholds.urgentLow, .red),
            (thresholds.low, .green),
            (thresholds.high, .green),
            (thresholds.urgentHigh, .red),
        ]
    }

    private var xDomain: ClosedRange<Date> {
        let end = model.now
        return end.addingTimeInterval(-Double(window.hours) * 3600)...end
    }

    private func yDomain(for series: [Reading]) -> ClosedRange<Double> {
        let values = series.map(\.value)
        let low = min(values.min() ?? thresholds.urgentLow, thresholds.urgentLow) - 0.5
        let high = max(values.max() ?? thresholds.urgentHigh, thresholds.urgentHigh) + 0.5
        return max(0, low)...high
    }
}
