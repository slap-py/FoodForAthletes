import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import UIKit

struct MealCaptureView: View {
    enum Step { case capture, review }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Query(sort: \MealLog.timestamp, order: .reverse) private var previousMeals: [MealLog]
    @State private var step: Step = .capture
    @State private var descriptionText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoData: [Data] = []
    @State private var photos: [UIImage] = []
    @State private var cameraPhoto: UIImage?
    @State private var draft: MealDraft?
    @State private var isPreparingPreview = false
    @State private var showsCamera = false
    @State private var showsCameraDenied = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var analysisError: String?
    @State private var showsOfflineQueuedConfirmation = false
    @FocusState private var descriptionFocused: Bool
    @AppStorage("unitSystem") private var unitSystem = "us"
    let loggingDate: Date
    let onCompleted: () -> Void

    init(loggingDate: Date = .now, onCompleted: @escaping () -> Void = {}) {
        self.loggingDate = loggingDate
        self.onCompleted = onCompleted
    }

    private var canAnalyze: Bool {
        (!descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) && !isPreparingPreview && !isTranscribing
    }

    private var usualMeals: [MealLog] {
        var seen = Set<String>()
        return previousMeals.filter { meal in
            let key = meal.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return seen.insert(key).inserted
        }.prefix(4).map { $0 }
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
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { descriptionFocused = false }
                }
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker(image: $cameraPhoto)
                .ignoresSafeArea()
        }
        .onChange(of: cameraPhoto) { _, image in
            guard let image, photos.count < 3 else { return }
            photos.append(image)
            if let data = image.analysisJPEGData() { photoData.append(data) }
            cameraPhoto = nil
        }
        .onChange(of: selectedPhotos) { _, items in
            loadPhotos(items)
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
        .alert("Meal queued", isPresented: $showsOfflineQueuedConfirmation) {
            Button("Done") { dismiss() }
        } message: {
            Text("Your meal and photos are saved securely on this iPhone. They’ll be analyzed automatically when your connection returns.")
        }
    }

    private var captureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Cancel") { dismiss() }
                    .font(.body).foregroundStyle(JournalTheme.moss)
                Text("Log a meal")
                    .font(.system(size: 31, weight: .bold)).tracking(-0.6)
                Text("Say it however you'd say it out loud. You'll see the estimate before it's saved.")
                    .font(.body).foregroundStyle(JournalTheme.ink.opacity(0.60))
                    .padding(.top, -10)

                if !Calendar.current.isDateInToday(loggingDate) {
                    Label("Logging for \(loggingDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(JournalTheme.moss)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(JournalTheme.sage.opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Rice bowl with chicken, avocado, and salsa", text: $descriptionText, axis: .vertical)
                        .focused($descriptionFocused)
                        .font(.body)
                        .lineLimit(4...7)
                        .padding(14)
                        .frame(minHeight: 116, alignment: .top)
                        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).stroke(JournalTheme.ink.opacity(0.10)) }
                        .submitLabel(.done)
                        .onSubmit { descriptionFocused = false }
                    HStack {
                        Spacer()
                        Button(action: requestCamera) {
                            Image(systemName: "camera").frame(width: 38, height: 38)
                                .background(JournalTheme.moss.opacity(0.10), in: Circle())
                        }
                        Button(action: toggleRecording) {
                            Group { if isTranscribing { ProgressView().tint(.white) } else { Image(systemName: isRecording ? "stop.fill" : "mic.fill") } }
                                .frame(width: 38, height: 38)
                                .background(isRecording ? JournalTheme.clay : JournalTheme.moss, in: Circle())
                                .foregroundStyle(.white)
                        }
                        .disabled(isTranscribing)
                        .accessibilityLabel(isRecording ? "Stop recording" : "Speak meal description")
                    }
                }

                photoSection

                Label("Add text or photos to continue. You can include up to three photos.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.65))
                Label("Photos are used only for this estimate and are never saved to your meal history or camera roll.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.58))

                Button(action: preparePreview) {
                    HStack {
                        if isPreparingPreview { ProgressView().tint(.white) }
                    Text(isPreparingPreview ? "Reviewing meal…" : "Analyze meal")
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAnalyze)
                .accessibilityHint(canAnalyze ? "Creates an approximate nutrition review" : "Add a description, a meal photo, or a nutrition-label photo first")

                if !usualMeals.isEmpty { usualRow }
            }
            .padding(18)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var usualRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENTS")
                .font(.caption.bold()).tracking(1.3).foregroundStyle(JournalTheme.moss)
            VStack(spacing: 9) {
                ForEach(usualMeals) { meal in
                    Button { repeatMeal(meal) } label: {
                        HStack(spacing: 11) {
                            Text(mealEmojiForCapture(meal.title)).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meal.title).font(.subheadline.bold()).lineLimit(1)
                                Text("\(Int(meal.calories)) kcal · \(meal.timestamp.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(JournalTheme.ink.opacity(0.55)).lineLimit(1)
                            }
                            Spacer()
                            Text("Log again").font(.caption.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                        }
                        .padding(13).background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.moss.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Logs the previously confirmed meal for the selected day without a photo")
                }
            }
        }
    }

    private var reviewStep: some View {
        ScrollView {
            if let draft {
                VStack(alignment: .leading, spacing: 18) {
                    Button("‹ Back") { step = .capture }
                        .font(.body).foregroundStyle(JournalTheme.moss)
                    Text(loggingDate, format: .dateTime.weekday(.short).month(.abbreviated).day().hour().minute())
                        .font(.caption.bold()).tracking(1.4).foregroundStyle(JournalTheme.moss)
                    Text(draft.title).font(.system(size: 29, weight: .bold)).tracking(-0.6).foregroundStyle(JournalTheme.ink)
                    JournalCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                reviewNutrient("Calories", draft.calories, JournalTheme.blue, unit: "kcal")
                            }
                            HStack {
                                reviewNutrient("Protein", draft.protein, JournalTheme.clay)
                                reviewNutrient("Carbs", draft.carbohydrates, JournalTheme.oat)
                                reviewNutrient("Fat", draft.fat, JournalTheme.sage)
                            }
                        }
                    }

                    JournalCard {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("Foods & portions").font(.headline)
                            ForEach(Array(draft.foods.enumerated()), id: \.offset) { _, food in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(food.name)
                                    Spacer()
                                    Text(PortionDisplay.text(food.portion, unitSystem: unitSystem)).foregroundStyle(.secondary)
                                    Button {
                                        step = .capture
                                        descriptionFocused = true
                                    } label: {
                                        Image(systemName: "pencil").font(.caption.bold()).foregroundStyle(JournalTheme.moss)
                                            .frame(width: 28, height: 28).background(JournalTheme.sage.opacity(0.30), in: Circle())
                                    }.buttonStyle(.plain).accessibilityLabel("Edit \(food.name)")
                                }
                                .font(.subheadline)
                            }
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

    private func reviewNutrient(_ label: String, _ value: Double, _ color: Color, unit: String = "g") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Int(value)) \(unit)").font(label == "Calories" ? .title.bold() : .title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value)) grams")
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Photos").font(.title3.bold())
                Text("Food, packaging, or nutrition labels — the estimate will identify each.").font(.caption).foregroundStyle(.secondary)
            }
            if !photos.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topTrailing) {
                                Button { clearPhoto(at: index) } label: {
                                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28).background(.ultraThinMaterial, in: Circle())
                                }.padding(5).accessibilityLabel("Remove photo \(index + 1)")
                            }
                    }
                }
            }
            if photos.count < 3 {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 3 - photos.count), matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.moss.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
            }
        }
    }

    private func mealEmojiForCapture(_ title: String) -> String {
        let value = title.lowercased()
        if value.contains("coffee") || value.contains("latte") { return "☕" }
        if value.contains("salmon") || value.contains("miso") || value.contains("noodle") { return "🍜" }
        if value.contains("bowl") || value.contains("salad") { return "🥗" }
        if value.contains("sandwich") || value.contains("toast") { return "🥪" }
        if value.contains("banana") { return "🍌" }
        return "🍽️"
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

    private func toggleRecording() {
        if isRecording {
            guard let recorder = audioRecorder else { return }
            recorder.stop()
            audioRecorder = nil
            isRecording = false
            isTranscribing = true
            Task {
                defer {
                    isTranscribing = false
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    try? FileManager.default.removeItem(at: recorder.url)
                }
                do {
                    let transcript = try await DayplateService.shared.transcribe(audioData: Data(contentsOf: recorder.url))
                    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        analysisError = "No speech was detected. Try speaking a little closer to the microphone."
                        return
                    }
                    let separator = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
                    descriptionText += separator + transcript
                } catch {
                    analysisError = "Couldn’t transcribe that recording: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { allowed in
            DispatchQueue.main.async {
                guard allowed else { analysisError = "Allow microphone access in Settings to speak your meal description."; return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .measurement)
                    try session.setActive(true)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dayplate-meal-\(UUID().uuidString).m4a")
                    let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                    guard recorder.prepareToRecord(), recorder.record() else {
                        throw NSError(domain: "DayplateRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone could not start recording."])
                    }
                    audioRecorder = recorder
                    isRecording = true
                } catch {
                    analysisError = "Couldn’t start recording. Please try again."
                }
            }
        }
    }

    private func preparePreview() {
        guard canAnalyze else { return }
        descriptionFocused = false
        guard networkMonitor.isConnected else {
            queueCurrentMealForLater()
            return
        }
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            do {
                let result = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(
                        description: descriptionText,
                        photoData: photoData
                    )
                )
                guard !Task.isCancelled else { return }
                draft = result
                step = .review
            } catch {
                if shouldQueue(error) {
                    queueCurrentMealForLater()
                } else {
                    analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func queueCurrentMealForLater() {
        do {
            try offlineMealQueue.enqueue(
                description: descriptionText,
                photoData: photoData
            )
            clearPhotos()
            showsOfflineQueuedConfirmation = true
        } catch {
            analysisError = "Couldn’t save this meal for offline analysis: \(error.localizedDescription)"
        }
    }

    private func shouldQueue(_ error: Error) -> Bool {
        guard !networkMonitor.isConnected else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return false }
            return [
                URLError.notConnectedToInternet,
                .networkConnectionLost,
                .timedOut,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed
            ].contains(URLError.Code(rawValue: nsError.code))
        }
        return true
    }

    private func saveMeal(_ draft: MealDraft) {
        let items = draft.foods.map { MealItem(canonicalName: $0.name, portion: $0.portion, sourceName: draft.ingredientSources[$0.name]) }
        let meal = MealLog(
            timestamp: loggingDate,
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
            loggingMethod: .ai,
            catalogVersion: draft.catalogVersion,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        clearPhotos()
        onCompleted()
        dismiss()
    }

    private func repeatMeal(_ source: MealLog) {
        let items = (source.items ?? []).map { MealItem(canonicalName: $0.canonicalName, portion: $0.portion, quantity: $0.quantity, catalogFoodID: $0.catalogFoodID, sourceRecordIDs: $0.sourceRecordIDs, brandName: $0.brandName, sourceName: $0.sourceName) }
        let meal = MealLog(
            timestamp: loggingDate,
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
            loggingMethod: .repeatMeal,
            catalogVersion: source.catalogVersion,
            items: items
        )
        modelContext.insert(meal)
        try? modelContext.save()
        onCompleted()
        dismiss()
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [(UIImage, Data)] = []
            for item in items.prefix(max(0, 3 - photos.count)) {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let compressed = image.analysisJPEGData() else { continue }
                loaded.append((image, compressed))
            }
            photos.append(contentsOf: loaded.map(\.0))
            photoData.append(contentsOf: loaded.map(\.1))
            selectedPhotos = []
        }
    }

    private func clearPhoto(at index: Int) {
        guard photos.indices.contains(index), photoData.indices.contains(index) else { return }
        photos.remove(at: index)
        photoData.remove(at: index)
        selectedPhotos = []
    }

    private func clearPhotos() {
        selectedPhotos = []
        photos = []
        photoData = []
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
    /// Keeps three temporary AI photos within the service request budget.
    func analysisJPEGData(maximumDimension: CGFloat = 1_280) -> Data? {
        let largestDimension = max(size.width, size.height)
        let image: UIImage
        if largestDimension > maximumDimension {
            let scale = maximumDimension / largestDimension
            let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            image = renderer.image { _ in draw(in: CGRect(origin: .zero, size: targetSize)) }
        } else {
            image = self
        }
        for quality in stride(from: 0.72, through: 0.44, by: -0.07) {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 2_000_000 { return data }
        }
        return image.jpegData(compressionQuality: 0.4)
    }
}
