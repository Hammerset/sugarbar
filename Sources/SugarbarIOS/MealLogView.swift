import PhotosUI
import SwiftUI
import SugarbarCore
import SugarbarUI

struct MealLogView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MealDraft()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isEstimating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                estimateSection
                reviewSection
                recentSection
            }
            .navigationTitle(draft.editing == nil ? "Log Meal" : "Edit Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
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
        }
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
                        Text(draft.estimate == nil ? "Estimate Carbs with Claude" : "Estimate Again")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!draft.canEstimate || isEstimating)
            } else {
                Text("Add a Claude API key in the Meals card to get an Estimate. You can still type the grams yourself.")
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
            MealReviewFields(draft: $draft)
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
                    Button {
                        draft = MealDraft(editing: meal)
                        errorMessage = nil
                    } label: {
                        Text(mealSummaryLine(meal))
                            .foregroundStyle(meal.id == draft.editing?.id ? Color.accentColor : .primary)
                    }
                }
                .onDelete { offsets in
                    for meal in offsets.map({ recent[$0] }) {
                        Task { await model.deleteMeal(meal) }
                        if meal.id == draft.editing?.id { draft = MealDraft() }
                    }
                }
            } header: {
                Text("Recent Meals")
            } footer: {
                Text("Tap to edit, swipe to delete. Editing or deleting a meal also updates its Apple Health entry.")
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

    private func save() {
        guard let meal = draft.meal() else { return }
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
