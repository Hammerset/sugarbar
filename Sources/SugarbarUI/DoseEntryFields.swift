import SwiftUI
import SugarbarCore

/// A manual Dose being entered or edited. An empty insulin name falls back to the last one used for that kind.
public struct DoseDraft: Equatable {
    public var units: Double
    public var kind: InsulinKind
    public var timestamp: Date
    public var insulinName: String
    public private(set) var editing: InsulinDose?

    public init() {
        units = 0
        kind = .bolus
        timestamp = Date()
        insulinName = ""
        editing = nil
    }

    public init(editing dose: InsulinDose) {
        units = dose.units
        kind = dose.kind
        timestamp = dose.timestamp
        insulinName = dose.insulinName ?? ""
        editing = dose
    }

    public var isValid: Bool { units > 0 && units <= maxManualDoseUnits }

    public func dose(defaultName: String?) -> InsulinDose? {
        guard isValid else { return nil }
        let name = insulinName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .manual(
            kind: kind,
            units: units,
            timestamp: timestamp,
            insulinName: name.isEmpty ? defaultName : name,
            entryId: editing?.entryId ?? UUID()
        )
    }
}

public let maxManualDoseUnits: Double = 100

/// The manual Dose rows shared by the Mac panel and the iOS sheet.
public struct DoseEntryFields: View {
    @Binding var draft: DoseDraft
    let defaultName: String?

    public init(draft: Binding<DoseDraft>, defaultName: String?) {
        _draft = draft
        self.defaultName = defaultName
    }

    public var body: some View {
        LabeledContent("Amount") {
            HStack {
                TextField("0", value: $draft.units, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 60)
                    .decimalKeyboard()
                Text("u").foregroundStyle(.secondary)
                Stepper("Amount", value: $draft.units, in: 0...maxManualDoseUnits, step: 0.5)
                    .labelsHidden()
            }
        }
        Picker("Kind", selection: $draft.kind) {
            Text("Bolus").tag(InsulinKind.bolus)
            Text("Basal").tag(InsulinKind.basal)
        }
        .pickerStyle(.segmented)
        DatePicker("Time", selection: $draft.timestamp, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
        LabeledContent("Insulin") {
            TextField("Insulin", text: $draft.insulinName, prompt: Text(defaultName ?? "Optional"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }

    public static let note = "Shown until the pen dose arrives from Glooko: a Glooko dose of the same kind and units within 20 minutes replaces it."
}

public func manualDoseSummary(_ dose: InsulinDose) -> String {
    "\(dose.timestamp.formatted(.dateTime.hour().minute())) · \(formatUnits(dose.units)) u \(dose.kind.label)"
        + (dose.insulinName.map { " · \($0)" } ?? "")
}
