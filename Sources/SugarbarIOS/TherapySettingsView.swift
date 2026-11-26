import SwiftUI
import SugarbarCore
import SugarbarUI

struct TherapySettingsView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var therapy: TherapySettings

    init(model: GlucoseViewModel) {
        self.model = model
        _therapy = State(initialValue: model.settings.therapy)
    }

    var body: some View {
        Form {
            if !model.therapySuggestions.isEmpty {
                Section {
                    ForEach(model.therapySuggestions, id: \.quantity) { suggestion in
                        TherapySuggestionRow(
                            suggestion: suggestion,
                            onAccept: {
                                model.acceptSuggestion(suggestion)
                                therapy[suggestion.quantity] = suggestion.suggested
                            },
                            onDismiss: { model.dismissSuggestion(suggestion) }
                        )
                    }
                }
            }
            Section {
                TherapySettingsFields(therapy: $therapy)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = therapy.validationError {
                        Text(error).foregroundStyle(.red)
                    }
                    Text(TherapySettingsFields.note)
                }
            }
            Section {
                TherapyEstimateRows(
                    estimate: model.therapyEstimate,
                    therapy: model.settings.therapy,
                    isEstimating: model.isEstimatingTherapy,
                    onEstimate: model.recomputeTherapyEstimate
                )
            } header: {
                Text("Learned from History")
            } footer: {
                Text(TherapyEstimateRows.note)
            }
            Section {
                CalibrationProposalRows(
                    report: model.calibration,
                    proposal: model.calibrationProposal,
                    isCalibrating: model.isCalibrating,
                    onCalibrate: model.recalibrate,
                    onApprove: { proposal in
                        model.approveCalibration(proposal)
                        therapy = model.settings.therapy
                    },
                    onReject: model.rejectCalibration
                )
            } header: {
                Text("Forecast Calibration")
            } footer: {
                Text(CalibrationProposalRows.note)
            }
            Section {
                ExcludedDaysRows(days: model.settings.therapyLearning.excludedDays, onSet: model.setExcludedDay)
            } header: {
                Text("Days Left Out of Calibration")
            } footer: {
                Text(ExcludedDaysRows.note)
            }
            Section {
                ForecastLearningRows(learning: model.forecastReview?.learning)
            } header: {
                Text("Forecast Timing Learned from History")
            } footer: {
                Text(ForecastLearningRows.note)
            }
            Section {
                TherapyVersionRows(
                    versions: model.settings.therapyLearning.versions,
                    current: model.settings.therapy,
                    scores: model.versionScores,
                    onRollBack: { version in
                        model.rollBack(to: version)
                        therapy = model.settings.therapy
                    }
                )
            } header: {
                Text("Therapy Settings Versions")
            } footer: {
                Text(TherapyVersionRows.note)
            }
            Section("Therapy Changes") {
                TherapyChangeLogRows(changes: model.settings.therapyLearning.changes)
            }
        }
        .navigationTitle("Therapy Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task {
            model.refreshTherapyEstimateIfDue()
            model.refreshCalibrationIfDue()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveTherapy(therapy)
                    dismiss()
                }
                .disabled(!therapy.isValid)
            }
        }
    }
}
