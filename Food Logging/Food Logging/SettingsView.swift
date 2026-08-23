import SwiftUI
import SwiftData
import CloudKit
import PhotosUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var healthStore: HealthKitStore
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Query private var meals: [MealLog]
    @Query private var water: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profilePhotoPath") private var profilePhotoPath = ""
    @AppStorage("insightsWindow") private var insightsWindow = "rolling"
    @AppStorage("waterLoggingEnabled") private var waterLoggingEnabled = false
    @State private var showsPrivacy = false
    @State private var showsHowItWorks = false
    @State private var showsDeleteConfirmation = false
    @State private var showsExport = false
    @State private var showsProfileEditor = false
    @State private var profileNameDraft = ""
    @State private var profilePhotoDraft: UIImage?
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var profileError: String?
    @State private var exportURLs: [URL] = []
    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Button {
                        beginProfileEdit()
                    } label: {
                    HStack(spacing: 14) {
                        ZStack(alignment: .bottomTrailing) {
                            ProfileAvatar(name: profileName, photoPath: profilePhotoPath, size: 58)
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(JournalTheme.moss, in: Circle())
                                .overlay(Circle().stroke(JournalTheme.paper, lineWidth: 2))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profileDisplayName).font(.title2.bold()).foregroundStyle(JournalTheme.ink)
                            Text("Your Dayplate").font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.55))
                        }
                    }
                    }
                    .buttonStyle(.plain)

                    DayplateSettingsGroup("LOGGING") {
                        DayplateSettingsPickerRow(title: "Units") {
                            Picker("Units", selection: $unitSystem) {
                                Text("U.S.").tag("us")
                                Text("Metric").tag("metric")
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        Divider()
                        DayplateSettingsPickerRow(title: "Insights period", subtitle: "How averages and the chart are grouped") {
                            Picker("Insights period", selection: $insightsWindow) {
                                Text("Rolling 7 days").tag("rolling")
                                Text("This week").tag("week")
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        Divider()
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Water logging").font(.body.weight(.medium))
                                Text("Adds a quick-add button to Today").font(.caption).foregroundStyle(JournalTheme.ink.opacity(0.55))
                            }
                            Spacer()
                            Toggle("Water logging", isOn: $waterLoggingEnabled).labelsHidden().tint(JournalTheme.moss)
                        }
                        if waterLoggingEnabled {
                            Divider()
                            DayplateSettingsPickerRow(title: "Quick-add amount") {
                                Picker("Quick-add amount", selection: $defaultWaterML) {
                                    Text(WaterDisplay.amount(240, unitSystem: unitSystem)).tag(240.0)
                                    Text(WaterDisplay.amount(355, unitSystem: unitSystem)).tag(355.0)
                                    Text(WaterDisplay.amount(500, unitSystem: unitSystem)).tag(500.0)
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }
                        Divider()
                        DayplateSettingsPickerRow(title: "Appearance") {
                            Picker("Appearance", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        Divider()
                        DayplateSettingsPickerRow(title: "Language") {
                            Picker("Language", selection: $appLanguage) {
                                Text("System").tag("system")
                                Text("English").tag("en_US")
                                Text("Spanish").tag("es_ES")
                                Text("French").tag("fr_FR")
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                    }

                    DayplateSettingsGroup("DATA") {
                        Button {
                            Task {
                                if case .connected = healthStore.connectionState { await healthStore.refreshToday() }
                                else { await healthStore.requestAuthorization() }
                            }
                        } label: {
                            DayplateSettingsValueRow(title: "Apple Health", value: healthStore.connectionState.label)
                        }
                        .buttonStyle(.plain)
                        .disabled(healthStore.connectionState == .loading || healthStore.connectionState == .unavailable)
                        Divider()
                        Button { showsExport = true } label: { DayplateSettingsValueRow(title: "Export your data", value: "CSV, JSON") }.buttonStyle(.plain)
                        Divider()
                        Button { showsHowItWorks = true } label: { DayplateSettingsValueRow(title: "How it works") }.buttonStyle(.plain)
                        Divider()
                        Button { showsPrivacy = true } label: { DayplateSettingsValueRow(title: "How your meal data is handled") }.buttonStyle(.plain)
                        if offlineMealQueue.pendingCount > 0 {
                            Divider()
                            HStack {
                                Label("\(offlineMealQueue.pendingCount) meal\(offlineMealQueue.pendingCount == 1 ? "" : "s") queued for analysis", systemImage: "tray.full.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(JournalTheme.moss)
                                Spacer()
                                Button("Retry") {
                                    offlineMealQueue.retryAll(in: modelContext)
                                    Task { await offlineMealQueue.processPending(into: modelContext, networkAvailable: networkMonitor.isConnected) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!networkMonitor.isConnected || offlineMealQueue.isProcessing)
                            }
                        }
                    }

                    DayplateSettingsGroup("ACCOUNT") {
                        Button {
                            beginProfileEdit()
                        } label: { DayplateSettingsValueRow(title: "Name & photo", value: profileDisplayName) }
                        .buttonStyle(.plain)
                        Divider()
                        ICloudStatusRow()
                        Divider()
                        Button("Delete all data", role: .destructive) { showsDeleteConfirmation = true }
                            .font(.body.weight(.medium)).foregroundStyle(JournalTheme.clay)
                    }

                    Text("Nutrition data v2026.7 · Dayplate \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3")")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.ink.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 128)
            }
            .background(JournalTheme.paper)
            .foregroundStyle(JournalTheme.ink)
            .tint(JournalTheme.moss)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showsPrivacy) { privacySheet }
            .sheet(isPresented: $showsHowItWorks) { howItWorksSheet }
            .sheet(isPresented: $showsExport) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("A copy you control", systemImage: "doc.on.doc")
                            .font(.title2.bold()).foregroundStyle(JournalTheme.ink)
                        Text("Generate JSON plus separate CSV files for meals, meal items, and water. Your profile photo is included when set. Everything is created entirely on this iPhone in Dayplate Exports.")
                            .font(.body).foregroundStyle(JournalTheme.ink.opacity(0.68))
                        if exportURLs.isEmpty {
                            Button {
                                generateExport()
                            } label: {
                                HStack {
                                    if isExporting { ProgressView().tint(.white) }
                                    Text(isExporting ? "Creating files…" : "Create export files")
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.borderedProminent).disabled(isExporting)
                        } else {
                            JournalCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Export created", systemImage: "checkmark.circle.fill").foregroundStyle(JournalTheme.moss)
                                    ForEach(exportURLs, id: \.self) { Text($0.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            ShareLink(items: exportURLs) {
                                Label("Share or save files", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Create a new export", action: generateExport)
                                .frame(maxWidth: .infinity)
                        }
                        Spacer()
                    }
                    .padding(22)
                    .background(JournalTheme.paper.ignoresSafeArea())
                        .navigationTitle("Export data")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsExport = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsProfileEditor) {
                NavigationStack {
                    Form {
                        Section("Profile") {
                            TextField("Name", text: $profileNameDraft)
                            HStack(spacing: 16) {
                                Group {
                                    if let profilePhotoDraft {
                                        Image(uiImage: profilePhotoDraft).resizable().scaledToFill()
                                    } else {
                                        ProfileAvatar(name: profileNameDraft, photoPath: "", size: 68)
                                    }
                                }
                                .frame(width: 68, height: 68).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 8) {
                                    PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                                        Label(profilePhotoDraft == nil ? "Choose photo" : "Change photo", systemImage: "photo")
                                    }
                                    if profilePhotoDraft != nil {
                                        Button("Remove photo", role: .destructive) { profilePhotoDraft = nil }
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(JournalTheme.paper)
                    .navigationTitle("Name & photo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsProfileEditor = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                saveProfile()
                            }
                            .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
                .onChange(of: selectedProfilePhoto) { _, item in
                    guard let item else { return }
                    Task {
                        defer { selectedProfilePhoto = nil }
                        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                            profileError = "That photo couldn’t be opened."
                            return
                        }
                        profilePhotoDraft = image
                    }
                }
            }
            .confirmationDialog("Delete all meal and water logs?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive, action: deleteAllData)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
        .alert("Couldn’t update profile", isPresented: Binding(get: { profileError != nil }, set: { if !$0 { profileError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(profileError ?? "Please try again.") }
        .alert("Couldn’t create export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "Please try again.") }
    }

    private var profileDisplayName: String { profileName.isEmpty ? "Your profile" : profileName }

    private func beginProfileEdit() {
        profileNameDraft = profileName
        profilePhotoDraft = ProfilePhotoStore.image(at: profilePhotoPath)
        selectedProfilePhoto = nil
        showsProfileEditor = true
    }

    private func saveProfile() {
        let trimmed = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if let profilePhotoDraft {
                profilePhotoPath = try ProfilePhotoStore.save(profilePhotoDraft, replacing: profilePhotoPath)
            } else {
                ProfilePhotoStore.remove(profilePhotoPath)
                profilePhotoPath = ""
            }
            profileName = trimmed
            showsProfileEditor = false
        } catch {
            profileError = error.localizedDescription
        }
    }

    private func generateExport() {
        isExporting = true
        defer { isExporting = false }
        do {
            exportURLs = try DataExportService.generate(meals: meals, water: water, profileName: profileName, profilePhotoPath: profilePhotoPath)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var privacySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your photos and meal details are handled with privacy in mind.")
                        .font(.body)
                        .foregroundStyle(JournalTheme.ink.opacity(0.72))
                    privacyRow(
                        title: "Photos are temporary unless queued",
                        message: "Photos are sent directly from this iPhone for the current AI review and are never saved with meal history. If you choose to log offline, photos are held only in protected device storage until analysis succeeds, then deleted.",
                        icon: "camera.fill"
                    )
                    privacyRow(
                        title: "Private storage",
                        message: "Your saved meal details live in your private app store and can sync with your private iCloud account. Provider credentials stay only on the Dayplate service.",
                        icon: "lock.icloud.fill"
                    )
                    privacyRow(
                        title: "Ingredient sources",
                        message: "Meal nutrition is sourced per food from USDA FoodData Central, then Open Food Facts, then AI-assisted web research when needed. Sources can be corroborated, and saved portions and primary sources remain attached to the meal for traceability.",
                        icon: "magnifyingglass"
                    )
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle("Photos & privacy")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsPrivacy = false } } }
        }
    }

    private var howItWorksSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A fast log now, followed by ingredient-level source checks in the background.")
                        .font(.body)
                        .foregroundStyle(JournalTheme.ink.opacity(0.72))
                    howItWorksRow(number: "1", title: "Understand your meal", message: "Text, up to three photos, and an optional voice note identify meal-level foods—even when a product or flavor name is approximate.")
                    howItWorksRow(number: "2", title: "Find nutrition", message: "Every food checks USDA first, then Open Food Facts, then AI-assisted web research. Failed or unit-mismatched results automatically move to the next source.")
                    howItWorksRow(number: "3", title: "Finish in the background", message: "The meal appears immediately while nutrition is resolved. Exact text-only results can be reused from the private on-device cache when you are offline.")
                    howItWorksRow(number: "4", title: "You stay in control", message: "If identity or portion remains ambiguous, the saved meal can show a quiet optional correction. Photos and recordings are used only to make the estimate; the saved result keeps nutrition and source details.")
                }
                .padding(22)
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHowItWorks = false } } }
        }
    }

    private func howItWorksRow(number: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(JournalTheme.moss, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(JournalTheme.ink)
                Text(message).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.7))
            }
        }
        .padding(15)
        .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func privacyRow(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.title3.bold())
                .foregroundStyle(JournalTheme.ink)
            Text(message)
                .font(.body)
                .foregroundStyle(JournalTheme.ink.opacity(0.72))
        }
    }

    private func preferencePicker<PickerContent: View>(
        title: String,
        description: String,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            picker()
                .foregroundStyle(JournalTheme.moss)
        }
    }

    private func deleteAllData() {
        meals.forEach(modelContext.delete)
        water.forEach(modelContext.delete)
        offlineMealQueue.deleteAll()
        try? modelContext.save()
    }

    private var healthButtonTitle: String {
        switch healthStore.connectionState {
        case .connected: "Refresh Health data"
        case .loading: "Connecting…"
        case .unavailable: "Apple Health unavailable"
        case .notRequested, .failed: "Connect Apple Health"
        }
    }
}

private struct SettingsDisclosureButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(JournalTheme.moss)
                    .frame(width: 34, height: 34)
                    .background(JournalTheme.sage.opacity(0.24), in: Circle())
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(JournalTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(JournalTheme.ink.opacity(0.45))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

private struct DayplateSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold)).tracking(1.4)
                .foregroundStyle(JournalTheme.moss)
            VStack(alignment: .leading, spacing: 13) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(JournalTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(JournalTheme.moss.opacity(0.12)))
        }
    }
}

private struct DayplateSettingsValueRow: View {
    let title: String
    var value: String?

    init(title: String, value: String? = nil) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.body).foregroundStyle(JournalTheme.ink)
            Spacer(minLength: 8)
            if let value { Text(value).font(.subheadline).foregroundStyle(JournalTheme.ink.opacity(0.5)).lineLimit(1) }
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(JournalTheme.ink.opacity(0.35))
        }.frame(minHeight: 28)
    }
}

private struct DayplateSettingsPickerRow<PickerContent: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let picker: PickerContent

    init(title: String, subtitle: String? = nil, @ViewBuilder picker: () -> PickerContent) {
        self.title = title
        self.subtitle = subtitle
        self.picker = picker()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(JournalTheme.ink.opacity(0.55)) }
            }
            Spacer(minLength: 6)
            picker.foregroundStyle(JournalTheme.moss)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(JournalTheme.ink)
            JournalCard {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(JournalTheme.ink)
    }
}

private struct ICloudStatusRow: View {
    @State private var status = "Checking…"

    var body: some View {
        LabeledContent("iCloud", value: status)
            .task {
                do {
                    let accountStatus = try await CKContainer(identifier: "iCloud.kaibergman.Food-Logging").accountStatus()
                    status = switch accountStatus {
                    case .available: "Connected"
                    case .noAccount: "Sign in required"
                    case .restricted: "Restricted"
                    case .couldNotDetermine, .temporarilyUnavailable: "Unavailable"
                    @unknown default: "Unavailable"
                    }
                } catch {
                    status = "Unavailable"
                }
            }
}
}
