import AppKit
import SwiftUI
import SugarbarCore
import SugarbarUI
import UniformTypeIdentifiers

struct MealLogWindow: View {
    let model: BarViewModel
    var onOpenSettings: () -> Void = {}

    @State private var draft = MealDraft()
    @State private var isEstimating = false
    @State private var errorMessage: String?
    @State private var showsFileImporter = false
    @State private var isDropTargeted = false
    @State private var pendingDelete: Meal?

    var body: some View {
        HStack(spacing: 0) {
            Form {
                photoSection
                estimateSection
                reviewSection
            }
            .formStyle(.grouped)
            .frame(width: 440)
            Divider()
            recentList
                .frame(width: 280)
        }
        .frame(height: 640)
        .onPasteCommand(of: [.fileURL, .image]) { providers in loadPhoto(from: providers) }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result { loadPhoto(at: url) }
        }
        .confirmationDialog(
            "Delete this meal?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { meal in
            Button("Delete", role: .destructive) { delete(meal) }
        } message: { meal in
            Text(mealSummaryLine(meal))
        }
    }

    private var photoSection: some View {
        Section {
            photoWell
            HStack {
                Button("Choose…", systemImage: "folder") { showsFileImporter = true }
                Button("Paste", systemImage: "doc.on.clipboard") { pastePhoto() }
                ContinuityCameraButton { setPhoto($0) }
                    .fixedSize()
                if draft.photoJPEG != nil {
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") { draft.photoJPEG = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove photo")
                }
            }
            TextField("Describe the meal, or add a note to the photo", text: $draft.note, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text(draft.editing == nil ? "Log Meal" : "Edit Meal")
        } footer: {
            Text("A photo, a description, or both. Drop or paste a photo, or take one with your iPhone.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var photoWell: some View {
        Group {
            if let jpeg = draft.photoJPEG, let image = NSImage(data: jpeg) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                    .overlay {
                        Label("Drop a photo here", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            loadPhoto(from: providers)
            return true
        }
    }

    private var estimateSection: some View {
        Section {
            if model.hasClaudeAPIKey {
                HStack {
                    Button(draft.estimate == nil ? "Estimate Carbs with Claude" : "Estimate Again") {
                        Task { await runEstimate() }
                    }
                    .disabled(!draft.canEstimate || isEstimating)
                    if isEstimating { ProgressView().controlSize(.small) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add your Claude API key in Settings to get a carb Estimate. You can still type the grams yourself.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: onOpenSettings)
                }
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
            HStack {
                Spacer()
                if draft.editing != nil {
                    Button("Cancel Edit") { reset() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(draft.editing == nil ? "Save Meal" : "Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        } footer: {
            Text(MealReviewFields.note + " Saved on this Mac only: not written to Apple Health and not shown on the phone.")
                .foregroundStyle(.secondary)
        }
    }

    private var recentList: some View {
        let recent = recentMeals(model.meals)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent Meals")
                .font(.headline)
                .padding([.top, .horizontal], 16)
            if recent.isEmpty {
                Text("Meals from the last two weeks show here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                List(recent) { meal in
                    HStack {
                        Text(mealSummaryLine(meal))
                            .font(.callout)
                            .foregroundStyle(meal.id == draft.editing?.id ? Color.accentColor : .primary)
                            .lineLimit(2)
                        Spacer()
                        Button("Edit", systemImage: "pencil") { edit(meal) }
                        Button("Delete", systemImage: "trash") { pendingDelete = meal }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .contextMenu {
                        Button("Edit") { edit(meal) }
                        Button("Delete", role: .destructive) { pendingDelete = meal }
                    }
                }
            }
        }
    }

    private func setPhoto(_ data: Data) {
        errorMessage = draft.setPhoto(data) ? nil : "Couldn't read that image."
    }

    private func loadPhoto(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) { setPhoto(data) } else { errorMessage = "Couldn't open that file." }
    }

    private func loadPhoto(from providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let data = url.flatMap { try? Data(contentsOf: $0) }
                Task { @MainActor in receive(data) }
            }
        } else {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in receive(data) }
            }
        }
    }

    private func receive(_ data: Data?) {
        if let data { setPhoto(data) } else { errorMessage = "Couldn't read that image." }
    }

    private func pastePhoto() {
        if let data = imageData(from: .general) { setPhoto(data) } else { errorMessage = "The clipboard has no image." }
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

    private func edit(_ meal: Meal) {
        draft = MealDraft(editing: meal)
        errorMessage = nil
    }

    private func delete(_ meal: Meal) {
        model.deleteMeal(meal)
        if meal.id == draft.editing?.id { reset() }
    }

    private func save() {
        guard let meal = draft.meal() else { return }
        model.saveMeal(meal)
        reset()
    }

    private func reset() {
        draft = MealDraft()
        errorMessage = nil
    }
}

/// A file URL first (a copied Finder file), then raw image data in any type ImageIO reads.
@MainActor
func imageData(from pasteboard: NSPasteboard) -> Data? {
    if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
       let data = try? Data(contentsOf: url) {
        return data
    }
    let types = [UTType.heic, .jpeg, .png, .tiff].map { NSPasteboard.PasteboardType($0.identifier) }
    if let type = pasteboard.availableType(from: types), let data = pasteboard.data(forType: type) { return data }
    return NSImage(pasteboard: pasteboard)?.tiffRepresentation
}

/// Continuity Camera: AppKit fills a menu item tagged `importFromDeviceIdentifier` with the nearby iPhones and iPads,
/// and hands the photo to the first responder that accepts images, which this button makes itself before opening the menu.
struct ContinuityCameraButton: NSViewRepresentable {
    let onImage: (Data) -> Void

    func makeNSView(context: Context) -> ContinuityCameraNSButton {
        let button = ContinuityCameraNSButton()
        button.onImage = onImage
        return button
    }

    func updateNSView(_ button: ContinuityCameraNSButton, context: Context) {
        button.onImage = onImage
    }
}

final class ContinuityCameraNSButton: NSButton, @preconcurrency NSServicesMenuRequestor {
    var onImage: ((Data) -> Void)?

    init() {
        super.init(frame: .zero)
        title = "Import from iPhone"
        image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .push
        target = self
        action = #selector(showDeviceMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func showDeviceMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let data = imageData(from: pasteboard) else { return false }
        onImage?(data)
        return true
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }
}
