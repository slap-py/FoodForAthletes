import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import UIKit
import Combine

struct MealCaptureView: View {
    enum Step { case capture, camera, clarify, review }
    enum PhotoSource { case camera, library }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Query(sort: \MealLog.timestamp, order: .reverse) private var previousMeals: [MealLog]
    @State private var step: Step = .capture
    @State private var descriptionText = ""
    @State private var selectedLibraryPhoto: PhotosPickerItem?
    @State private var photoData: [Data] = []
    @State private var photos: [UIImage] = []
    @StateObject private var camera = DayplateCameraController()
    @State private var cameraPhotoData: Data?
    @State private var cameraPhotoAddedToMeal = false
    @State private var identifiedPhotoFoods: [String] = []
    @State private var identifiedFoodsBeforeCameraPhoto: [String]?
    @State private var cameraFoods: [String] = []
    @State private var isDetectingCameraFoods = false
    @State private var cameraDetectionRequestID = UUID()
    @State private var cameraDetectionError: String?
    @State private var isAddingCameraFood = false
    @State private var newCameraFood = ""
    @State private var photoSource: PhotoSource = .camera
    @State private var isLoadingLibraryPhoto = false
    @State private var draft: MealDraft?
    @State private var clarificationQuestions: [MealClarification] = []
    @State private var clarificationIndex = 0
    @State private var clarificationAnswers: [String: String] = [:]
    @State private var isPreparingPreview = false
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
                case .camera: cameraStep
                case .clarify: clarificationStep
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
        .onReceive(camera.$capturedImage.compactMap { $0 }) { image in
            handleCapturedPhoto(image)
        }
        .onChange(of: selectedLibraryPhoto) { _, item in
            guard let item else { return }
            reviewLibraryPhoto(item)
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
                    Label("Logging for \(loggingDate.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale)))", systemImage: "calendar")
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

                Button { preparePreview() } label: {
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

    private var cameraStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button("‹ Back") { leaveCamera() }
                    .font(.body)
                    .foregroundStyle(JournalTheme.moss)

                Text(photoSource == .library ? "Review a photo" : "Take a photo")
                    .font(.system(size: 31, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(JournalTheme.ink)

                Text("The meal itself, the packaging, or a nutrition label — any of the three works.")
                    .font(.body)
                    .foregroundStyle(JournalTheme.ink.opacity(0.58))
                    .padding(.top, -10)

                cameraViewfinder

                if cameraPhotoData == nil {
                    if isLoadingLibraryPhoto {
                        HStack(spacing: 10) {
                            ProgressView().tint(JournalTheme.moss)
                            Text("Preparing photo…")
                        }
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                        .frame(maxWidth: .infinity, minHeight: 78)
                    } else {
                        HStack(spacing: 34) {
                            PhotosPicker(selection: $selectedLibraryPhoto, matching: .images) {
                                VStack(spacing: 7) {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.title3)
                                        .frame(width: 52, height: 52)
                                        .background(JournalTheme.card, in: Circle())
                                    Text("Photos").font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(JournalTheme.moss)
                            }

                            Button {
                                photoSource = .camera
                                camera.capture()
                            } label: {
                                ZStack {
                                    Circle().stroke(JournalTheme.moss.opacity(0.22), lineWidth: 5)
                                    Circle().fill(JournalTheme.moss).padding(7)
                                }
                                .frame(width: 78, height: 78)
                            }
                            .buttonStyle(.plain)
                            .disabled(!camera.isReady)
                            .accessibilityLabel("Take photo")

                            Color.clear.frame(width: 52, height: 52)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Text("Photos are used for this estimate only.")
                        .font(.subheadline)
                        .foregroundStyle(JournalTheme.ink.opacity(0.48))
                        .frame(maxWidth: .infinity)
                } else {
                    cameraFindings
                }
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            if photoSource == .camera && cameraPhotoData == nil && !isLoadingLibraryPhoto { camera.start() }
        }
        .onDisappear { camera.stop() }
    }

    private var cameraViewfinder: some View {
        ZStack {
            if let image = camera.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                DayplateCameraPreview(session: camera.session)
            }

            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(JournalTheme.card.opacity(0.65), lineWidth: 2)
                .padding(16)

            if (!camera.isReady || isLoadingLibraryPhoto) && camera.capturedImage == nil {
                ProgressView()
                    .tint(.white)
                    .padding(16)
                    .background(.black.opacity(0.28), in: Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(JournalTheme.mint)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(JournalTheme.moss.opacity(0.18), lineWidth: 1)
        }
        .clipped()
    }

    private var cameraFindings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("I found:")
                    .font(.title3.bold())
                    .foregroundStyle(JournalTheme.ink)
                Spacer()
                if photoSource == .library {
                    PhotosPicker(selection: $selectedLibraryPhoto, matching: .images) {
                        Text("Choose another")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(JournalTheme.moss)
                    }
                } else {
                    Button("Retake") { retakePhoto() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(JournalTheme.moss)
                }
            }

            if isDetectingCameraFoods {
                HStack(spacing: 11) {
                    ProgressView().tint(JournalTheme.moss)
                    Text("Looking for foods…")
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                }
                .frame(maxWidth: .infinity, minHeight: 74)
                .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            } else {
                ForEach(Array(cameraFoods.enumerated()), id: \.offset) { index, food in
                    HStack(spacing: 12) {
                        Text(food)
                            .font(.body)
                            .foregroundStyle(JournalTheme.ink)
                        Spacer()
                        Button { cameraFoods.remove(at: index) } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline)
                                .foregroundStyle(JournalTheme.clay)
                                .frame(width: 34, height: 34)
                                .background(JournalTheme.clay.opacity(0.11), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(food)")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 62)
                    .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(JournalTheme.moss.opacity(0.10), lineWidth: 1)
                    }
                }

                if let cameraDetectionError {
                    Text(cameraDetectionError)
                        .font(.caption)
                        .foregroundStyle(JournalTheme.clay)
                }

                if isAddingCameraFood {
                    HStack {
                        TextField("Food name", text: $newCameraFood)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .onSubmit(addCameraFood)
                        Button("Add", action: addCameraFood)
                            .fontWeight(.semibold)
                            .disabled(newCameraFood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 58)
                    .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                } else {
                    Button { isAddingCameraFood = true } label: {
                        Label("Add a food", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(JournalTheme.moss)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .overlay {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .stroke(JournalTheme.moss.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            }
                    }
                    .buttonStyle(.plain)
                }

                Button(action: continueFromCamera) {
                    HStack(spacing: 9) {
                        if isPreparingPreview { ProgressView().tint(.white) }
                        Text(isPreparingPreview ? "Reviewing meal…" : "Continue")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(JournalTheme.moss, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPreparingPreview)
            }
        }
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
                                Text("\(Int(meal.calories)) kcal · \(meal.timestamp.formatted(.relative(presentation: .named).locale(locale)))")
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

    private var clarificationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button("‹ Back") {
                    step = .capture
                    descriptionFocused = true
                }
                .font(.body)
                .foregroundStyle(JournalTheme.moss)

                Text("One quick check")
                    .font(.system(size: 31, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(JournalTheme.ink)

                if clarificationQuestions.indices.contains(clarificationIndex) {
                    let question = clarificationQuestions[clarificationIndex]
                    Text("Question \(clarificationIndex + 1) of \(clarificationQuestions.count)")
                        .font(.caption.bold())
                        .tracking(1.2)
                        .foregroundStyle(JournalTheme.moss)

                    JournalCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(question.prompt)
                                .font(.title3.bold())
                                .foregroundStyle(JournalTheme.ink)
                            Text(question.detail)
                                .font(.subheadline)
                                .foregroundStyle(JournalTheme.ink.opacity(0.62))
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(question.options) { option in
                            Button {
                                answerClarification(question, with: option)
                            } label: {
                                HStack {
                                    Text(option.label)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: option.action == "edit" ? "pencil" : "chevron.right")
                                }
                                .font(.body.weight(.semibold))
                                .foregroundStyle(option.action == "edit" ? JournalTheme.ink.opacity(0.68) : JournalTheme.moss)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(JournalTheme.moss.opacity(0.14), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isPreparingPreview)
                        }
                    }

                    if isPreparingPreview {
                        HStack(spacing: 10) {
                            ProgressView().tint(JournalTheme.moss)
                            Text("Checking sources again…")
                        }
                        .font(.subheadline)
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
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
                PhotosPicker(selection: $selectedLibraryPhoto, matching: .images) {
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
            step = .camera
        case .notDetermined:
            Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                if allowed { step = .camera } else { showsCameraDenied = true }
            }
        default:
            showsCameraDenied = true
        }
    }

    private func handleCapturedPhoto(_ image: UIImage) {
        guard cameraPhotoData == nil, let data = image.analysisJPEGData() else { return }
        camera.stop()
        cameraPhotoData = data
        isDetectingCameraFoods = true
        cameraDetectionError = nil
        cameraFoods = []
        let requestID = UUID()
        cameraDetectionRequestID = requestID
        Task {
            do {
                let foods = try await DayplateService.shared.detectFoods(photoData: data)
                guard cameraDetectionRequestID == requestID else { return }
                cameraFoods = foods
                if cameraFoods.isEmpty {
                    cameraDetectionError = "I couldn’t identify a food in the quick review. You can still continue—the full meal analysis will inspect the photo again."
                }
            } catch {
                guard cameraDetectionRequestID == requestID else { return }
                cameraDetectionError = "Quick photo recognition wasn’t available. You can still continue—the full meal analysis will inspect the photo again."
            }
            guard cameraDetectionRequestID == requestID else { return }
            isDetectingCameraFoods = false
        }
    }

    private func reviewLibraryPhoto(_ item: PhotosPickerItem) {
        resetCurrentPhoto(startCamera: false)
        photoSource = .library
        isLoadingLibraryPhoto = true
        step = .camera
        camera.stop()
        Task {
            defer {
                isLoadingLibraryPhoto = false
                selectedLibraryPhoto = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                analysisError = "That photo couldn’t be opened. Please choose another one."
                return
            }
            camera.review(image)
        }
    }

    private func addCameraFood() {
        let food = newCameraFood.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !food.isEmpty else { return }
        cameraFoods.append(food)
        newCameraFood = ""
        isAddingCameraFood = false
    }

    private func continueFromCamera() {
        guard let data = cameraPhotoData, let image = camera.capturedImage else { return }
        if !cameraPhotoAddedToMeal, photos.count < 3 {
            identifiedFoodsBeforeCameraPhoto = identifiedPhotoFoods
            photos.append(image)
            photoData.append(data)
            for food in cameraFoods where !identifiedPhotoFoods.contains(where: { $0.localizedCaseInsensitiveCompare(food) == .orderedSame }) {
                identifiedPhotoFoods.append(food)
            }
            cameraPhotoAddedToMeal = true
        }
        preparePreview()
    }

    private func retakePhoto() {
        photoSource = .camera
        resetCurrentPhoto(startCamera: true)
    }

    private func resetCurrentPhoto(startCamera: Bool) {
        if cameraPhotoAddedToMeal {
            if let data = cameraPhotoData, photoData.last == data, !photos.isEmpty {
                photoData.removeLast()
                photos.removeLast()
            }
            if let identifiedFoodsBeforeCameraPhoto { identifiedPhotoFoods = identifiedFoodsBeforeCameraPhoto }
        }
        cameraPhotoData = nil
        cameraPhotoAddedToMeal = false
        identifiedFoodsBeforeCameraPhoto = nil
        cameraFoods = []
        cameraDetectionError = nil
        isDetectingCameraFoods = false
        cameraDetectionRequestID = UUID()
        isAddingCameraFood = false
        newCameraFood = ""
        camera.resetPhoto()
        if startCamera { camera.start() }
    }

    private func leaveCamera() {
        resetCurrentPhoto(startCamera: false)
        photoSource = .camera
        camera.stop()
        step = .capture
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

    private func preparePreview(usingClarifications: Bool = false) {
        guard canAnalyze else { return }
        descriptionFocused = false
        if !usingClarifications {
            clarificationAnswers = [:]
            clarificationQuestions = []
            clarificationIndex = 0
        }
        guard networkMonitor.isConnected else {
            queueCurrentMealForLater()
            return
        }
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            do {
                let result = try await MealAnalysisService.shared.analyzeOutcome(
                    MealAnalysisInput(
                        description: descriptionText,
                        photoData: photoData,
                        identifiedFoods: identifiedPhotoFoods,
                        allowsClarification: true,
                        clarificationAnswers: clarificationAnswers
                    )
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .draft(let completedDraft):
                    draft = completedDraft
                    clarificationQuestions = []
                    clarificationIndex = 0
                    step = .review
                case .needsClarification(let questions):
                    clarificationQuestions = Array(questions.prefix(2))
                    clarificationIndex = 0
                    step = .clarify
                }
            } catch {
                if shouldQueue(error) {
                    queueCurrentMealForLater()
                } else {
                    analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func answerClarification(_ question: MealClarification, with option: MealClarification.Option) {
        if option.action == "edit" {
            step = .capture
            descriptionFocused = true
            return
        }
        clarificationAnswers[question.id] = option.value
        if clarificationIndex + 1 < clarificationQuestions.count {
            clarificationIndex += 1
        } else {
            preparePreview(usingClarifications: true)
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

    private func clearPhoto(at index: Int) {
        guard photos.indices.contains(index), photoData.indices.contains(index) else { return }
        photos.remove(at: index)
        photoData.remove(at: index)
        selectedLibraryPhoto = nil
    }

    private func clearPhotos() {
        selectedLibraryPhoto = nil
        photos = []
        photoData = []
        identifiedPhotoFoods = []
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private final class DayplateCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    @Published private(set) var capturedImage: UIImage?

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.dayplate.camera-session", qos: .userInitiated)
    private var isConfigured = false

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.isConfigured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isReady = true }
            } catch {
                DispatchQueue.main.async { self.isReady = false }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isReady = false }
        }
    }

    func capture() {
        guard isReady else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .auto
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func resetPhoto() {
        capturedImage = nil
    }

    func review(_ image: UIImage) {
        isReady = false
        capturedImage = image
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NSError(domain: "DayplateCamera", code: 1)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw NSError(domain: "DayplateCamera", code: 2)
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        isConfigured = true
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.capturedImage = image
            self.isReady = false
        }
    }
}

private struct DayplateCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
