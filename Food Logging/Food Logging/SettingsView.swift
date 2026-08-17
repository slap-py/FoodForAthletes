import SwiftUI
import SwiftData
import CloudKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var meals: [MealLog]
    @Query private var water: [WaterLog]
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
    @State private var showsPrivacy = false
    @State private var showsDeleteConfirmation = false
    @State private var showsExport = false
    @State private var openAIKey = ""
    @State private var foodDataKey = ""
    @State private var credentialsSaved = APIKeyStore.hasCredentials
    @State private var credentialError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .foregroundStyle(JournalTheme.ink)

                    SettingsSection("Preferences") {
                        preferencePicker(title: "Units", description: "Choose U.S. or metric measurements") {
                            Picker("Units", selection: $unitSystem) {
                                Text("U.S.").tag("us")
                                Text("Metric").tag("metric")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        Divider()
                        preferencePicker(title: "Default water size", description: "Amount added with Quick water") {
                            Picker("Default water size", selection: $defaultWaterML) {
                                Text(WaterDisplay.amount(240, unitSystem: unitSystem)).tag(240.0)
                                Text(WaterDisplay.amount(355, unitSystem: unitSystem)).tag(355.0)
                                Text(WaterDisplay.amount(500, unitSystem: unitSystem)).tag(500.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    SettingsSection("Sync") {
                        ICloudStatusRow()
                        Divider()
                        Text("Your device store is ready for private iCloud sync. No separate Food for Athletes account is needed.")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.62))
                    }

                    SettingsSection("Privacy") {
                        Button("How your meal data is handled") { showsPrivacy = true }
                    }

                    SettingsSection("Direct AI analysis") {
                        Text("This personal app sends meal inputs directly from your iPhone to OpenAI and USDA FoodData Central. Your keys are stored only in the device Keychain and are never synced with meal data.")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.62))
                        SecureField("OpenAI API key", text: $openAIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .padding(12)
                            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                        SecureField("USDA FoodData Central API key", text: $foodDataKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .padding(12)
                            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Text(credentialsSaved ? "Keys saved on this iPhone" : "Add both keys to enable photo analysis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(credentialsSaved ? JournalTheme.moss : .secondary)
                            Spacer()
                            Button("Save keys", action: saveKeys)
                                .buttonStyle(.bordered)
                        }
                        if credentialsSaved {
                            Button("Remove saved keys", role: .destructive, action: removeKeys)
                                .font(.caption)
                        }
                    }

                    SettingsSection("Your data") {
                        Button("Export data") { showsExport = true }
                        Divider()
                        Button("Delete all data", role: .destructive) { showsDeleteConfirmation = true }
                            .foregroundStyle(.red)
                    }

                    Text("Food for Athletes estimates are approximate and are designed to reveal meal timing and nutrient distribution—not to prescribe targets.")
                        .font(.footnote)
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
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
            .sheet(isPresented: $showsExport) {
                NavigationStack {
                    ContentUnavailableView("Export outline", systemImage: "square.and.arrow.up", description: Text("A portable export will be added before release. Your records remain in your private app store."))
                        .navigationTitle("Export data")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsExport = false } } }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog("Delete all meal and water logs?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive, action: deleteAllData)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Couldn’t save keys", isPresented: Binding(get: { credentialError != nil }, set: { if !$0 { credentialError = nil } })) {
                Button("OK", role: .cancel) { credentialError = nil }
            } message: {
                Text(credentialError ?? "Please try again.")
            }
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
                        title: "Photos are temporary",
                        message: "You can add a meal photo and a nutrition-label photo. Each is sent directly from this iPhone for the current AI review, is never written to your camera roll, and is never saved with your meal history.",
                        icon: "camera.fill"
                    )
                    privacyRow(
                        title: "Private storage",
                        message: "Your saved meal details live in your private app store and can sync with your private iCloud account. Personal API keys stay only in this iPhone's Keychain.",
                        icon: "lock.icloud.fill"
                    )
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(JournalTheme.paper.ignoresSafeArea())
            .navigationTitle("Photos & privacy")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsPrivacy = false } } }
        }
        .preferredColorScheme(.light)
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
                Text(description)
                    .font(.caption)
                    .foregroundStyle(JournalTheme.ink.opacity(0.58))
            }
            Spacer(minLength: 8)
            picker()
                .foregroundStyle(JournalTheme.moss)
        }
    }

    private func deleteAllData() {
        meals.forEach(modelContext.delete)
        water.forEach(modelContext.delete)
        try? modelContext.save()
    }

    private func saveKeys() {
        do {
            if !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try APIKeyStore.save(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .openAI)
                openAIKey = ""
            }
            if !foodDataKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try APIKeyStore.save(foodDataKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .foodDataCentral)
                foodDataKey = ""
            }
            credentialsSaved = APIKeyStore.hasCredentials
            if !credentialsSaved { credentialError = "Add both an OpenAI API key and a USDA FoodData Central API key." }
        } catch {
            credentialError = error.localizedDescription
        }
    }

    private func removeKeys() {
        APIKeyStore.delete(.openAI)
        APIKeyStore.delete(.foodDataCentral)
        credentialsSaved = false
        openAIKey = ""
        foodDataKey = ""
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
