import PhotosUI
import SwiftUI
import SugarbarCore
import SugarbarUI

struct MealLogView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: MealEntryMode
    @State private var draft = MealDraft()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isEstimating = false
    @State private var errorMessage: String?
    @State private var isLoadingStrategy = false
    @State private var strategyError: String?
    @State private var doseDraft = DoseDraft()
    @State private var showDoseLog = false
    @State private var showTherapySettings = false
    @State private var showEarlierDoseLog = false

    init(model: GlucoseViewModel, mode: MealEntryMode = .log) {
        self.model = model
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.editing?.isEaten != true {
                    Section {
                        Picker("Mode", selection: $mode) {
                            Text("Plan").tag(MealEntryMode.plan)
                            Text("Eating now").tag(MealEntryMode.log)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                photoSection
                estimateSection
                reviewSection
                if mode == .plan {
                    MealPlanSections(
                        draft: $draft,
                        suggestion: model.doseSuggestion(carbs: draft.carbsGrams),
                        pendingTherapySuggestions: model.therapySuggestions,
                        doseCoverage: model.doseCoverage,
                        penStep: model.settings.dosing.penStep,
                        canAskClaude: model.hasClaudeAPIKey,
                        isLoadingStrategy: isLoadingStrategy,
                        strategyError: strategyError,
                        onRequestStrategy: { Task { await runStrategy() } },
                        onLogDose: openDoseLog,
                        onSavePlan: { save(as: .planned) },
                        onOpenTherapySettings: { showTherapySettings = true },
                        onLogEarlierDose: { showEarlierDoseLog = true }
                    )
                }
                recentSection
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .plan ? "Save Plan" : "Save") { save(as: mode == .plan ? .planned : .eaten) }
                        .disabled(!draft.isValid)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { setPhoto(data) }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if let data = image.jpegData(compressionQuality: 0.9) { setPhoto(data) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showTherapySettings, onDismiss: model.reloadSettings) {
                TherapySettingsView(model: model)
            }
            .sheet(isPresented: $showEarlierDoseLog) {
                DoseLogView(model: model)
            }
            .sheet(isPresented: $showDoseLog) {
                DoseLogView(model: model, initialDraft: doseDraft) { dose in
                    Task { await doseLogged(dose) }
                }
            }
        }
    }

    private var title: String {
        if mode == .plan { return draft.isEditingPlan ? "Edit Plan" : "Plan Meal" }
        if draft.isEditingPlan { return "Eating Now" }
        return draft.editing == nil ? "Log Meal" : "Edit Meal"
    }

    private var photoSection: some View {
        Section {
            if let jpeg = draft.photoJPEG, let image = UIImage(data: jpeg) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Spacer()
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Library", systemImage: "photo")
                }
            }
            .buttonStyle(.bordered)
            TextField("Describe the meal, or add a note to the photo", text: $draft.note, axis: .vertical)
        } footer: {
            Text("A photo, a description, or both. Dictate with the keyboard's microphone.")
        }
    }

    private var estimateSection: some View {
        Section {
            if model.hasClaudeAPIKey {
                Button {
                    Task { await runEstimate() }
                } label: {
                    if isEstimating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(draft.estimate == nil ? "Estimate with Claude" : "Estimate Again")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!draft.canEstimate || isEstimating)
            } else {
                Text("Add a Claude API key in the Meals card to get an Estimate and a dose strategy. You can still type the grams yourself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let estimate = draft.estimate {
                MealEstimateDetails(estimate: estimate)
            }
        }
    }

    private var reviewSection: some View {
        Section {
            MealReviewFields(draft: $draft, mode: mode)
        } footer: {
            Text(MealReviewFields.note)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = recentMeals(model.meals)
        if !recent.isEmpty {
            Section {
                ForEach(recent) { meal in
                    HStack {
                        Button {
                            start(MealDraft(editing: meal), mode: meal.isPlanned ? .plan : .log)
                        } label: {
                            Text(mealSummaryLine(meal))
                                .foregroundStyle(meal.id == draft.editing?.id ? Color.accentColor : .primary)
                        }
                        if meal.isPlanned {
                            Spacer()
                            Button("Eating Now") { start(MealDraft(eating: meal), mode: .log) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .onDelete { offsets in
                    for meal in offsets.map({ recent[$0] }) {
                        Task { await model.deleteMeal(meal) }
                        if meal.id == draft.editing?.id { start(MealDraft(), mode: mode) }
                    }
                }
            } header: {
                Text("Plans and Recent Meals")
            } footer: {
                Text("Tap to edit, swipe to delete. A plan becomes the eaten Meal when you tap Eating Now. Editing or deleting an eaten meal also updates its Apple Health entry.")
            }
        }
    }

    private func setPhoto(_ data: Data) {
        errorMessage = draft.setPhoto(data) ? nil : "Couldn't read that image."
    }

    private func runEstimate() async {
        isEstimating = true
        errorMessage = nil
        defer { isEstimating = false }
        do {
            draft.apply(try await model.estimateMeal(draft))
        } catch {
            logDiagnostic("mealEstimate", error)
            errorMessage = error.sugarbarMessage
        }
    }

    private func start(_ newDraft: MealDraft, mode newMode: MealEntryMode) {
        draft = newDraft
        mode = newMode
        errorMessage = nil
        strategyError = nil
    }

    private func runStrategy() async {
        isLoadingStrategy = true
        strategyError = nil
        defer { isLoadingStrategy = false }
        do {
            let strategy = try await model.mealStrategy(for: draft, suggestion: model.doseSuggestion(carbs: draft.carbsGrams))
            draft.apply(strategy, penStep: model.settings.dosing.penStep)
        } catch {
            logDiagnostic("mealStrategy", error)
            strategyError = error.sugarbarMessage
        }
    }

    private func openDoseLog() {
        var dose = DoseDraft()
        dose.units = draft.unitsToLogNow
        dose.kind = .bolus
        doseDraft = dose
        showDoseLog = true
    }

    /// Logging part of the plan's dose keeps the plan, so what is left stays visible as a reminder.
    private func doseLogged(_ dose: InsulinDose) async {
        guard dose.kind == .bolus else { return }
        draft.takenUnits += dose.units
        let state: MealState = draft.editing?.isEaten == true ? .eaten : .planned
        guard let meal = draft.meal(state: state) else { return }
        await model.saveMeal(meal)
        draft.markSaved(meal)
    }

    private func save(as state: MealState) {
        guard let meal = draft.meal(state: state) else { return }
        Task { await model.saveMeal(meal) }
        dismiss()
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
