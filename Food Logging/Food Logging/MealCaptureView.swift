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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoImage: UIImage?
    @State private var draft: MealDraft?
    @State private var isPreparingPreview = false
    @State private var showsCamera = false
    @State private var showsCameraDenied = false
    @FocusState private var descriptionFocused: Bool

    private var canAnalyze: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoImage != nil && !isPreparingPreview
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
            CameraPicker(image: $photoImage)
                .ignoresSafeArea()
        }
        .onChange(of: photoImage) { _, image in
            if let image { photoData = image.jpegData(compressionQuality: 0.82) }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photoData = data
                    photoImage = image
                }
            }
        }
        .alert("Camera access is off", isPresented: $showsCameraDenied) {
            Button("Open Settings") { openSystemSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings, or choose a photo from your library.")
        }
    }

    private var captureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !usualMeals.isEmpty { usualRow }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe what you ate")
                        .font(.title2.bold())
                    Text("A short sentence is enough. Include sauces, drinks, or portions when useful.")
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

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Add a meal photo").font(.title2.bold())
                        Text("Required")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(JournalTheme.oat.opacity(0.32), in: Capsule())
                    }
                    if let photoImage {
                        Image(uiImage: photoImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(alignment: .topTrailing) {
                                Button { clearPhoto() } label: {
                                    Image(systemName: "xmark").font(.headline)
                                        .frame(width: 44, height: 44)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .padding(10)
                                .accessibilityLabel("Remove meal photo")
                            }
                    } else {
                        HStack(spacing: 12) {
                            Button(action: requestCamera) {
                                photoButtonLabel("Take photo", icon: "camera.fill")
                            }
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                photoButtonLabel("Choose photo", icon: "photo.on.rectangle")
                            }
                        }
                    }
                    Label("Used for the current preview only; never saved with your meal.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                }

                JournalCard {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "sparkles").foregroundStyle(JournalTheme.clay)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI analysis is not connected yet").font(.subheadline.bold())
                            Text("Analyze meal opens an illustrative review card. Nothing is uploaded and the nutrient values are placeholders.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

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
                .accessibilityHint(canAnalyze ? "Opens an illustrative meal review" : "Enter a description and add a photo first")
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
                        Text("Illustrative preview — AI food analysis is not connected")
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
                        .accessibilityHint("Saves the text and illustrative nutrient snapshot, then discards the photo")
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

    private func requestCamera() {
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
            try? await Task.sleep(for: .milliseconds(550))
            draft = PlaceholderMealAnalysis.draft(for: descriptionText)
            isPreparingPreview = false
            step = .review
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
            assumptions: draft.assumptions,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        clearPhoto()
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
            assumptions: source.assumptions,
            sourceMealID: source.id,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        dismiss()
    }

    private func clearPhoto() {
        selectedPhoto = nil
        photoData = nil
        photoImage = nil
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
