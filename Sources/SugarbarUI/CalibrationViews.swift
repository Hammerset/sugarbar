import SwiftUI
import SugarbarCore

/// The Calibration proposal with what it changes, how much better it did on held-out days, and Approve / Reject.
public struct CalibrationProposalRows: View {
    let report: CalibrationReport?
    let proposal: CalibrationProposal?
    let isCalibrating: Bool
    let onCalibrate: () -> Void
    let onApprove: (CalibrationProposal) -> Void
    let onReject: (CalibrationProposal) -> Void

    public init(
        report: CalibrationReport?,
        proposal: CalibrationProposal?,
        isCalibrating: Bool,
        onCalibrate: @escaping () -> Void,
        onApprove: @escaping (CalibrationProposal) -> Void,
        onReject: @escaping (CalibrationProposal) -> Void
    ) {
        self.report = report
        self.proposal = proposal
        self.isCalibrating = isCalibrating
        self.onCalibrate = onCalibrate
        self.onApprove = onApprove
        self.onReject = onReject
    }

    public static let note = "Fitted by replaying the Forecast over the last 90 days: the insulin curve and sensitivity on corrections only, then carbs on logged meals. The last 7 days are held out to check the result. Each proposal moves a setting at most 15%, and nothing changes until you approve it."

    public var body: some View {
        if let proposal {
            VStack(alignment: .leading, spacing: 6) {
                Label("Proposed forecast settings", systemImage: "slider.horizontal.3")
                ForEach(proposal.changes, id: \.quantity) { change in
                    LabeledContent(change.quantity.name) {
                        Text("\(change.quantity.format(change.current)) → \(change.quantity.format(change.proposed))")
                    }
                }
                Text(evidenceLine(proposal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report { horizonGrid(report, proposal) }
                HStack {
                    Button("Approve") { onApprove(proposal) }
                        .buttonStyle(.borderedProminent)
                    Button("Reject") { onReject(proposal) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        } else if let report {
            Text(noProposalLine(report))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let drift = report?.drift, drift.episodes > 0 {
            Text(driftLine(drift))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if let report {
                Text("Calibrated \(report.computedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCalibrating {
                ProgressView().controlSize(.small)
            } else {
                Button("Calibrate Now", action: onCalibrate)
            }
        }
    }

    private func evidenceLine(_ proposal: CalibrationProposal) -> String {
        var sources: [String] = []
        if proposal.corrections > 0 { sources.append("\(proposal.corrections) correction episodes") }
        if proposal.meals > 0 { sources.append("\(proposal.meals) meal episodes") }
        let percent = Int((proposal.improvement * 100).rounded())
        return "On the last 7 days, held out from the fit: error ±\(two(proposal.heldOutError)) → ±\(two(proposal.proposedHeldOutError)) mmol/L, \(percent)% better. Fitted on \(sources.joined(separator: " and "))."
    }

    @ViewBuilder
    private func horizonGrid(_ report: CalibrationReport, _ proposal: CalibrationProposal) -> some View {
        let stage = proposal.meals > 0 ? report.carbs : report.insulin
        if let stage, let now = stage.heldOut[stage.current], let next = stage.heldOut[stage.capped] {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Held out").gridColumnAlignment(.leading)
                    Text("Now")
                    Text("Proposed")
                }
                .foregroundStyle(.secondary)
                ForEach(forecastScoreHorizons, id: \.self) { minute in
                    if let before = now.errors[minute], let after = next.errors[minute] {
                        GridRow {
                            Text("\(minute) min")
                            Text(cell(before))
                            Text(cell(after))
                        }
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func cell(_ error: ForecastError) -> String {
        String(format: "±%.2f (%+.2f)", error.meanAbsoluteError, error.bias)
    }

    private func noProposalLine(_ report: CalibrationReport) -> String {
        guard let insulin = report.insulin else {
            return "No correction episodes to calibrate from yet: a Bolus with no food from three hours before to five hours after."
        }
        let episodes = insulin.fitted[insulin.current]?.episodes ?? 0
        return "No change proposed: nothing within 15% of the current settings beat them on the held-out days, from \(episodes) correction episodes."
    }

    private func driftLine(_ drift: QuietDrift) -> String {
        func rate(_ value: Double?) -> String { value.map { String(format: "%+.2f mmol/L per hour", $0) } ?? "–" }
        return "With no Bolus or Meal for five hours, glucose drifts \(rate(drift.night)) at night and \(rate(drift.day)) by day."
    }

    private func two(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// Days left out of calibration, with a reason, and a way to mark another.
public struct ExcludedDaysRows: View {
    let days: [ExcludedDay]
    let onSet: (String, ExcludedDay.Reason?) -> Void

    @State private var date = Date()
    @State private var reason = ExcludedDay.Reason.sick

    public init(days: [ExcludedDay], onSet: @escaping (String, ExcludedDay.Reason?) -> Void) {
        self.days = days
        self.onSet = onSet
    }

    public static let note = "Days that do not represent how your insulin usually works are left out of calibration: being sick, a lot of exercise, alcohol, or a misbehaving sensor."

    public var body: some View {
        ForEach(days.reversed()) { day in
            HStack {
                Text(label(day))
                Spacer()
                Text(day.reason.label).foregroundStyle(.secondary)
                Button {
                    onSet(day.day, nil)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Include \(label(day)) again")
            }
        }
        HStack {
            DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
            Picker("Reason", selection: $reason) {
                ForEach(ExcludedDay.Reason.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            Button("Leave Out") {
                onSet(ExcludedDay(date: date, reason: reason, calendar: .current).day, reason)
            }
        }
    }

    private func label(_ day: ExcludedDay) -> String {
        day.date(calendar: .current)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()) ?? day.day
    }
}

/// Every version of the Therapy Settings, newest first, with how the Forecast did under it and a way back to it.
public struct TherapyVersionRows: View {
    let versions: [TherapyVersion]
    let current: TherapySettings
    let scores: [UUID: ForecastScorecard]
    let onRollBack: (TherapyVersion) -> Void

    @State private var pending: TherapyVersion?

    public init(versions: [TherapyVersion], current: TherapySettings, scores: [UUID: ForecastScorecard], onRollBack: @escaping (TherapyVersion) -> Void) {
        self.versions = versions
        self.current = current
        self.scores = scores
        self.onRollBack = onRollBack
    }

    public static let note = "Accuracy is from the Forecasts this device logged while each version was in place, so it shows how the Forecast did before and after every change."

    public var body: some View {
        if versions.isEmpty {
            Text("No versions yet: one is kept every time the Therapy Settings change.").foregroundStyle(.secondary)
        } else {
            let newestFirst = Array(versions.enumerated().reversed())
            ForEach(newestFirst, id: \.element.id) { index, version in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(version.isBaseline ? "Earlier settings" : version.date.formatted(date: .abbreviated, time: .shortened))
                        if index == versions.count - 1, version.therapy == current {
                            Text("In use").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        if version.therapy != current {
                            Button("Roll Back") { pending = version }
                                .controlSize(.small)
                        }
                    }
                    Text(version.evidence).font(.caption).foregroundStyle(.secondary)
                    if index > 0 {
                        Text(changeLine(from: versions[index - 1].therapy, to: version.therapy))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(accuracyLine(scores[version.id]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                "Roll back the Therapy Settings?",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                presenting: pending
            ) { version in
                Button("Roll Back") { onRollBack(version) }
            } message: { version in
                Text(changeLine(from: current, to: version.therapy))
            }
        }
    }

    private func changeLine(from old: TherapySettings, to new: TherapySettings) -> String {
        let changed = TherapyQuantity.allCases.filter { old[$0] != new[$0] }.map { quantity in
            "\(quantity.name) \(old[quantity].map(quantity.format) ?? "not set") → \(new[quantity].map(quantity.format) ?? "not set")"
        }
        return changed.isEmpty ? "No change" : changed.joined(separator: ", ")
    }

    private func accuracyLine(_ card: ForecastScorecard?) -> String {
        guard let card else { return "No logged Forecasts" }
        let parts = [30, 60].compactMap { minute -> String? in
            let error = card.error(atMinute: minute)
            return error.count > 0 ? String(format: "±%.2f at %d min", error.meanAbsoluteError, minute) : nil
        }
        return parts.isEmpty ? "No scored Forecasts yet" : parts.joined(separator: ", ") + " (\(card.forecastCount) Forecasts)"
    }
}
