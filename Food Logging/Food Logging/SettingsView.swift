import SwiftUI
import SwiftData
import CloudKit

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
    @State private var showsPrivacy = false
    @State private var showsHowItWorks = false
    @State private var showsDeleteConfirmation = false
    @State private var showsExport = false

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
                        preferencePicker(title: "Appearance", description: "Use the system look, light, or dark") {
                            Picker("Appearance", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        Divider()
                        preferencePicker(title: "Language", description: "Choose the language used for dates") {
                            Picker("Language", selection: $appLanguage) {
                                Text("System").tag("system")
                                Text("English").tag("en_US")
                                Text("Spanish").tag("es_ES")
                                Text("French").tag("fr_FR")
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
                        Text("Your device store is ready for private iCloud sync. No separate Dayplate account is needed.")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.62))
                    }

                    SettingsSection("Apple Health") {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                                .frame(width: 34, height: 34)
                                .background(.red.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(healthStore.connectionState.label)
                                    .font(.headline)
                                Text("Reads today’s workouts and active calories. Health data is never written by this app.")
                                    .font(.caption)
                                    .foregroundStyle(JournalTheme.ink.opacity(0.62))
                            }
                        }
                        Divider()
                        Button(healthButtonTitle) {
                            Task {
                                if case .connected = healthStore.connectionState {
                                    await healthStore.refreshToday()
                                } else {
                                    await healthStore.requestAuthorization()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(healthStore.connectionState == .loading || healthStore.connectionState == .unavailable)
                    }

                    SettingsSection("Privacy") {
                        SettingsDisclosureButton(
                            title: "How your meal data is handled",
                            icon: "hand.raised.fill",
                            action: { showsPrivacy = true }
                        )
                    }

                    SettingsSection("Food & AI service") {
                        SettingsDisclosureButton(
                            title: "How it works",
                            icon: "questionmark.circle",
                            action: { showsHowItWorks = true }
                        )
                        if offlineMealQueue.pendingCount > 0 {
                            Divider()
                            HStack {
                                Label("\(offlineMealQueue.pendingCount) meal\(offlineMealQueue.pendingCount == 1 ? "" : "s") queued for analysis", systemImage: "tray.full.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(JournalTheme.moss)
                                Spacer()
                                Button("Retry") {
                                    Task { await offlineMealQueue.processPending(into: modelContext) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!networkMonitor.isConnected || offlineMealQueue.isProcessing)
                            }
                        }
                    }

                    SettingsSection("Your data") {
                        Button("Export data") { showsExport = true }
                        Divider()
                        Button("Delete all data", role: .destructive) { showsDeleteConfirmation = true }
                            .foregroundStyle(.red)
                    }

                    Text("Dayplate estimates are approximate and are designed to reveal meal timing and nutrient distribution—not to prescribe targets.")
                        .font(.footnote)
                        .foregroundStyle(JournalTheme.ink.opacity(0.58))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3")")
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
                        message: "Meal nutrition is sourced per ingredient from USDA FoodData Central, Open Food Facts when needed for branded products, and a manufacturer-site fallback. Saved portions and sources remain attached to the meal for traceability.",
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
                    Text("A fast, ingredient-level estimate with source checks before you save.")
                        .font(.body)
                        .foregroundStyle(JournalTheme.ink.opacity(0.72))
                    howItWorksRow(number: "1", title: "Understand your meal", message: "Text, up to three photos, and an optional voice note identify meal-level foods such as chicken breast, bun, or sauce.")
                    howItWorksRow(number: "2", title: "Find nutrition", message: "Generic foods use USDA FoodData Central. Branded foods check USDA’s branded database, then Open Food Facts, then an official manufacturer page if needed.")
                    howItWorksRow(number: "3", title: "Check the result", message: "A separate AI sanity check looks for implausible amounts or unit mistakes before the review is shown.")
                    howItWorksRow(number: "4", title: "You stay in control", message: "Review each food and portion before saving. Photos and recordings are used only to make that estimate; your saved meal keeps the resulting nutrition and source details.")
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
