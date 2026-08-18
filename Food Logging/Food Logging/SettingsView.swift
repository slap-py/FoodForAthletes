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
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
    @State private var showsPrivacy = false
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
                        Button("How your meal data is handled") { showsPrivacy = true }
                    }

                    SettingsSection("Food & AI service") {
                        Text("Food search uses FatSecret’s standard search endpoint as the primary source and USDA FoodData Central as a supplement. Meal analysis sends the description and any photos you choose to Dayplate, which passes your inputs to OpenAI. Provider keys stay on the service and are never stored in this app.")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.ink.opacity(0.62))
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
                        title: "Catalog search is separate from AI",
                        message: "Food search checks FatSecret first and then supplements it with USDA FoodData Central. Results are intentionally shown separately for now; saved source details and portions remain attached to the meal for traceability.",
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
