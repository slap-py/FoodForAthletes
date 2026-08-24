import SwiftUI
import SwiftData
import PhotosUI

/// Re-estimating goes through the same durable queue as a first-time log: the
/// saved meal flips to pending and the sheet closes immediately instead of
/// holding the user on a spinner until the service answers.
struct MealReestimateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    let meal: MealLog
    @State private var descriptionText: String
    @State private var timestamp: Date
    @State private var photos: [UIImage] = []
    @State private var photoData: [Data] = []
    @State private var selectedLibraryPhoto: PhotosPickerItem?
    @State private var isLoadingLibraryPhoto = false
    @State private var errorMessage: String?
    @FocusState private var descriptionFocused: Bool

    init(meal: MealLog) {
        self.meal = meal
        _descriptionText = State(initialValue: meal.descriptionText)
        _timestamp = State(initialValue: meal.timestamp)
    }

    private var canSubmit: Bool {
        !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    JournalCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Refine the original description", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(JournalTheme.moss)
                            Text("Update what you ate, then Dayplate re-estimates in the background and replaces this saved meal when it finishes.")
                                .font(.subheadline)
                                .foregroundStyle(JournalTheme.ink.opacity(0.68))
                        }
                    }

                    field("What did you eat?") {
                        TextField("Describe the meal", text: $descriptionText, axis: .vertical)
                            .focused($descriptionFocused)
                            .lineLimit(4...8)
                    }

                    field("When did you eat it?") {
                        DatePicker("", selection: $timestamp, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .tint(JournalTheme.moss)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    field("Photos") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The original photo was not kept, so add one again if it helps the estimate.")
                                .font(.caption).foregroundStyle(JournalTheme.ink.opacity(0.55))
                            if !photos.isEmpty {
                                HStack(spacing: 10) {
                                    ForEach(Array(photos.enumerated()), id: \.offset) { index, image in
                                        Image(uiImage: image)
                                            .resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 96)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .overlay(alignment: .topTrailing) {
                                                Button { removePhoto(at: index) } label: {
                                                    Image(systemName: "xmark").font(.caption.bold())
                                                        .frame(width: 28, height: 28).background(.ultraThinMaterial, in: Circle())
                                                }
                                                .padding(5)
                                                .accessibilityLabel("Remove photo \(index + 1)")
                                            }
                                    }
                                }
                            }
                            if photos.count < 3 {
                                PhotosPicker(selection: $selectedLibraryPhoto, matching: .images) {
                                    HStack(spacing: 8) {
                                        if isLoadingLibraryPhoto { ProgressView().tint(JournalTheme.moss) }
                                        Label(isLoadingLibraryPhoto ? "Preparing photo…" : "Attach a photo", systemImage: "photo.on.rectangle")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(JournalTheme.moss)
                                    .frame(maxWidth: .infinity).frame(height: 46)
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.moss.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [5])))
                                }
                            }
                        }
                    }

                    Button(action: submit) {
                        Text("Re-estimate meal").frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                }
                .padding(18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { descriptionFocused = false }
                }
            }
        }
        .onChange(of: selectedLibraryPhoto) { _, item in
            guard let item else { return }
            loadLibraryPhoto(item)
        }
        .alert("Couldn’t re-estimate this meal", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            JournalCard { content() }
        }
    }

    private func loadLibraryPhoto(_ item: PhotosPickerItem) {
        isLoadingLibraryPhoto = true
        Task {
            defer {
                isLoadingLibraryPhoto = false
                selectedLibraryPhoto = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let analysisData = image.analysisJPEGData() else {
                errorMessage = "That photo couldn’t be opened. Please choose another one."
                return
            }
            photos.append(image)
            photoData.append(analysisData)
        }
    }

    private func removePhoto(at index: Int) {
        guard photos.indices.contains(index), photoData.indices.contains(index) else { return }
        photos.remove(at: index)
        photoData.remove(at: index)
    }

    private func submit() {
        guard canSubmit else { return }
        descriptionFocused = false
        let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try offlineMealQueue.reestimate(
                meal: meal,
                description: trimmed,
                photoData: photoData,
                timestamp: timestamp,
                in: modelContext
            )
            dismiss()
            Task { await offlineMealQueue.processPending(into: modelContext, networkAvailable: networkMonitor.isConnected) }
        } catch {
            errorMessage = "Couldn’t queue this re-estimate: \(error.localizedDescription)"
        }
    }
}
