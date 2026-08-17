import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import UIKit

struct MealCaptureView: View {
    enum Step { case capture, review }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealLog.timestamp, order: .reverse) private var previousMeals: [MealLog]
    @State private var step: Step = .capture
    @State private var descriptionText = ""
    @State private var selectedMealPhoto: PhotosPickerItem?
    @State private var selectedLabelPhoto: PhotosPickerItem?
    @State private var mealPhotoData: Data?
    @State private var labelPhotoData: Data?
    @State private var mealPhotoImage: UIImage?
    @State private var labelPhotoImage: UIImage?
    @State private var draft: MealDraft?
    @State private var isPreparingPreview = false
    @State private var showsCamera = false
    @State private var showsCameraDenied = false
    @State private var cameraTarget: PhotoTarget = .meal
    @State private var analysisError: String?
    @FocusState private var descriptionFocused: Bool

    private enum PhotoTarget { case meal, nutritionLabel }

    private var canAnalyze: Bool {
        (!descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mealPhotoImage != nil || labelPhotoImage != nil) && !isPreparingPreview
    }

    private var usualMeals: [MealLog] {
        let currentHour = Calendar.current.component(.hour, from: .now)
        var seen = Set<String>()
        return previousMeals.filter { meal in
            let hour = Calendar.current.component(.hour, from: meal.timestamp)
            return abs(hour - currentHour) <= 2 && seen.insert(meal.title.lowercased()).inserted
        }.prefix(3).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .capture: captureStep
                case .review: reviewStep
                }
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle(step == .capture ? "Log a meal" : "Review meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .capture ? "Cancel" : "Back") {
                        if step == .review { step = .capture } else { dismiss() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker(image: cameraTarget == .meal ? $mealPhotoImage : $labelPhotoImage)
                .ignoresSafeArea()
        }
        .onChange(of: mealPhotoImage) { _, image in
            if let image { mealPhotoData = image.analysisJPEGData() }
        }
        .onChange(of: labelPhotoImage) { _, image in
            if let image { labelPhotoData = image.analysisJPEGData() }
        }
        .onChange(of: selectedMealPhoto) { _, item in
            load(item, as: .meal)
        }
        .onChange(of: selectedLabelPhoto) { _, item in
            load(item, as: .nutritionLabel)
        }
        .alert("Camera access is off", isPresented: $showsCameraDenied) {
            Button("Open Settings") { openSystemSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings, or choose a photo from your library.")
        }
        .alert("Couldn’t analyze this meal", isPresented: Binding(get: { analysisError != nil }, set: { if !$0 { analysisError = nil } })) {
            Button("OK", role: .cancel) { analysisError = nil }
        } message: {
            Text(analysisError ?? "Please try again.")
        }
    }

    private var captureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !usualMeals.isEmpty { usualRow }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Describe what you ate")
                        Text("Optional")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(JournalTheme.sage.opacity(0.38), in: Capsule())
                    }
                        .font(.title2.bold())
                    Text("A short sentence improves the estimate. Include sauces, drinks, or portions when useful.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Rice bowl with chicken, avocado, and salsa", text: $descriptionText, axis: .vertical)
                        .focused($descriptionFocused)
                        .lineLimit(3...6)
                        .padding(14)
                        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.ink.opacity(0.09)) }
                        .submitLabel(.done)
                }

                photoSection(
                    title: "Meal photo",
                    detail: "Optional · shows ingredients and visible portions",
                    image: mealPhotoImage,
                    picker: $selectedMealPhoto,
                    target: .meal
                )

                photoSection(
                    title: "Nutrition-label photo",
                    detail: "Optional · helps use the packaged serving values",
                    image: labelPhotoImage,
                    picker: $selectedLabelPhoto,
                    target: .nutritionLabel
                )

                Label("Add text or either photo to continue. You can include at most two photos.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.65))
                Label("Photos are used only for this estimate and are never saved to your meal history or camera roll.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.58))

                Button(action: preparePreview) {
                    HStack {
                        if isPreparingPreview { ProgressView().tint(.white) }
                        Text(isPreparingPreview ? "Preparing review…" : "Analyze meal")
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAnalyze)
                .accessibilityHint(canAnalyze ? "Creates an approximate nutrition review" : "Add a description, a meal photo, or a nutrition-label photo first")
            }
            .padding(18)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var usualRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("USUAL AROUND NOW")
                .font(.caption.bold()).tracking(1.3).foregroundStyle(JournalTheme.moss)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(usualMeals) { meal in
                        Button { repeatMeal(meal) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meal.title).font(.subheadline.bold()).lineLimit(1)
                                Text("Log again now").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(13)
                            .frame(width: 180, alignment: .leading)
                            .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Logs the previously confirmed meal at the current time without a photo")
                    }
                }
            }
        }
    }

    private var reviewStep: some View {
        ScrollView {
            if let draft {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(JournalTheme.clay)
                        Text("Approximate AI nutrition estimate")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(JournalTheme.clay)
                    }

                    JournalCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(Date.now, format: .dateTime.hour().minute())
                                .font(.caption.bold()).tracking(1).foregroundStyle(JournalTheme.moss)
                            Text(draft.title).font(.title.bold()).foregroundStyle(JournalTheme.ink)
                            HStack {
                                reviewNutrient("Carbs", draft.carbohydrates, JournalTheme.oat)
                                reviewNutrient("Protein", draft.protein, JournalTheme.clay)
                            }
                            HStack {
                                reviewNutrient("Fat", draft.fat, JournalTheme.sage)
                                reviewNutrient("Fiber", draft.fiber, JournalTheme.blue)
                            }
                            Divider()
                            LabeledContent("Estimated energy", value: "\(Int(draft.calories)) kcal")
                                .font(.subheadline)
                        }
                    }

                    JournalCard {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("Foods & approachable portions").font(.headline)
                            ForEach(Array(draft.foods.enumerated()), id: \.offset) { _, food in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(food.name)
                                    Spacer()
                                    Text(food.portion).foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                            Text(draft.assumptions)
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                        }
                    }

                    Button("Edit description") {
                        step = .capture
                        descriptionFocused = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Save meal") { saveMeal(draft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Saves the nutrient snapshot, then permanently discards both temporary photos")
                }
                .padding(18)
            }
        }
    }

    private func reviewNutrient(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Int(value)) g").font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value)) grams")
    }

    private func photoButtonLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.subheadline.bold())
        }
        .foregroundStyle(JournalTheme.moss)
        .frame(maxWidth: .infinity, minHeight: 106)
        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(JournalTheme.moss.opacity(0.35)) }
    }

    private func photoSection(
        title: String,
        detail: String,
        image: UIImage?,
        picker: Binding<PhotosPickerItem?>,
        target: PhotoTarget
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        Button { clearPhoto(target) } label: {
                            Image(systemName: "xmark").font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Remove \(title.lowercased())")
                    }
            } else {
                HStack(spacing: 12) {
                    Button { requestCamera(for: target) } label: {
                        photoButtonLabel("Take photo", icon: "camera.fill")
                    }
                    PhotosPicker(selection: picker, matching: .images) {
                        photoButtonLabel("Choose photo", icon: "photo.on.rectangle")
                    }
                }
            }
        }
    }

    private func requestCamera(for target: PhotoTarget) {
        cameraTarget = target
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showsCameraDenied = true
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showsCamera = true
        case .notDetermined:
            Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                if allowed { showsCamera = true } else { showsCameraDenied = true }
            }
        default:
            showsCameraDenied = true
        }
    }

    private func preparePreview() {
        guard canAnalyze else { return }
        descriptionFocused = false
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            do {
                let result = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(
                        description: descriptionText,
                        mealPhotoData: mealPhotoData,
                        nutritionLabelPhotoData: labelPhotoData
                    )
                )
                guard !Task.isCancelled else { return }
                draft = result
                step = .review
            } catch {
                analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func saveMeal(_ draft: MealDraft) {
        let items = draft.foods.map { MealItem(canonicalName: $0.name, portion: $0.portion) }
        let meal = MealLog(
            title: draft.title,
            descriptionText: descriptionText,
            calories: draft.calories,
            carbohydrates: draft.carbohydrates,
            protein: draft.protein,
            fat: draft.fat,
            fiber: draft.fiber,
            calcium: draft.calcium,
            iron: draft.iron,
            magnesium: draft.magnesium,
            potassium: draft.potassium,
            sodium: draft.sodium,
            vitaminD: draft.vitaminD,
            assumptions: draft.assumptions,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        clearPhotos()
        dismiss()
    }

    private func repeatMeal(_ source: MealLog) {
        let items = (source.items ?? []).map { MealItem(canonicalName: $0.canonicalName, portion: $0.portion) }
        let meal = MealLog(
            title: source.title,
            descriptionText: source.descriptionText,
            calories: source.calories,
            carbohydrates: source.carbohydrates,
            protein: source.protein,
            fat: source.fat,
            fiber: source.fiber,
            calcium: source.calcium,
            iron: source.iron,
            magnesium: source.magnesium,
            potassium: source.potassium,
            sodium: source.sodium,
            vitaminD: source.vitaminD,
            assumptions: source.assumptions,
            sourceMealID: source.id,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        dismiss()
    }

    private func load(_ item: PhotosPickerItem?, as target: PhotoTarget) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                switch target {
                case .meal:
                    mealPhotoData = data
                    mealPhotoImage = image
                case .nutritionLabel:
                    labelPhotoData = data
                    labelPhotoImage = image
                }
            }
        }
    }

    private func clearPhoto(_ target: PhotoTarget) {
        switch target {
        case .meal:
            selectedMealPhoto = nil
            mealPhotoData = nil
            mealPhotoImage = nil
        case .nutritionLabel:
            selectedLabelPhoto = nil
            labelPhotoData = nil
            labelPhotoImage = nil
        }
    }

    private func clearPhotos() {
        clearPhoto(.meal)
        clearPhoto(.nutritionLabel)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private extension UIImage {
    /// Keeps temporary AI payloads fast to upload without creating a file or photo-library asset.
    func analysisJPEGData(maximumDimension: CGFloat = 1_600) -> Data? {
        let largestDimension = max(size.width, size.height)
        guard largestDimension > maximumDimension else { return jpegData(compressionQuality: 0.82) }
        let scale = maximumDimension / largestDimension
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: targetSize)) }
            .jpegData(compressionQuality: 0.82)
    }
}
