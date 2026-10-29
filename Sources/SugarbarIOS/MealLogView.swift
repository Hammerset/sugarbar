import PhotosUI
import SwiftUI
import SugarbarCore

struct MealLogView: View {
    let model: GlucoseViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var note = ""
    @State private var timestamp = Date()
    @State private var estimate: MealEstimate?
    @State private var carbsText = ""
    @State private var summary = ""
    @State private var isEstimating = false
    @State private var errorMessage: String?

    private var carbsGrams: Double? {
        Double(carbsText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                estimateSection
                reviewSection
            }
            .navigationTitle("Log Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled((carbsGrams ?? 0) <= 0)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let picked = UIImage(data: data) {
                        image = picked
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image = $0 }
                    .ignoresSafeArea()
            }
        }
    }

    private var photoSection: some View {
        Section {
            if let image {
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
            TextField("Note, e.g. “ate half the bread”", text: $note, axis: .vertical)
        } footer: {
            Text("Dictate the note with the keyboard's microphone.")
        }
    }

    private var estimateSection: some View {
        Section {
            Button {
                Task { await runEstimate() }
            } label: {
                if isEstimating {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(estimate == nil ? "Estimate Carbs with Claude" : "Estimate Again")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(image == nil || isEstimating)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let estimate {
                ForEach(estimate.items, id: \.self) { item in
                    Text(item)
                }
                if !estimate.assumptions.isEmpty {
                    Text("Assumed: " + estimate.assumptions.joined(separator: "; "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Confidence: \(estimate.confidence)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reviewSection: some View {
        Section {
            LabeledContent("Carbs (g)") {
                TextField("0", text: $carbsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            TextField("Description", text: $summary)
            DatePicker("Time", selection: $timestamp, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
        } footer: {
            Text("Claude's estimate is a starting point — check the grams before saving. Not a medical device.")
        }
    }

    private func runEstimate() async {
        guard let image, let jpeg = jpegData(for: image) else { return }
        isEstimating = true
        errorMessage = nil
        defer { isEstimating = false }
        do {
            let result = try await model.estimateMeal(imageJPEG: jpeg, note: note)
            estimate = result
            carbsText = formatGrams(result.carbsGrams)
            if summary.isEmpty { summary = result.summary }
        } catch {
            logDiagnostic("mealEstimate", error)
            errorMessage = error.sugarbarMessage
        }
    }

    private func save() {
        guard let carbsGrams, carbsGrams > 0 else { return }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let meal = Meal(timestamp: timestamp, carbsGrams: carbsGrams, summary: trimmed.isEmpty ? "Meal" : trimmed)
        Task { await model.logMeal(meal) }
        dismiss()
    }
}

/// Phone photos are 12 MP; Claude only needs enough pixels to recognise the plate.
private func jpegData(for image: UIImage, maxDimension: CGFloat = 1280) -> Data? {
    let scale = min(1, maxDimension / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    return resized.jpegData(compressionQuality: 0.75)
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
