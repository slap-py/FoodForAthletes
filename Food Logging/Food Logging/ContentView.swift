import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case today, history, insights, you
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Query(sort: \WaterLog.timestamp) private var waterLogs: [WaterLog]
    @State private var selectedTab: AppTab = .today
    @State private var showsLogFood = false
    @State private var historySelectedDate = Calendar.current.startOfDay(for: .now)
    @State private var loggingDate = Date.now
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("unitSystem") private var unitSystem = "us"
    @AppStorage("defaultWaterML") private var defaultWaterML = 240.0
    @AppStorage("waterLoggingEnabled") private var waterLoggingEnabled = false

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var locale: Locale {
        appLanguage == "system" ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }

    var body: some View {
        currentTabContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(JournalTheme.paper.ignoresSafeArea())
        .environment(\.locale, locale)
        .preferredColorScheme(preferredColorScheme)
        .task {
            if UserDefaults.standard.bool(forKey: "dayplate.openLogFood") {
                UserDefaults.standard.removeObject(forKey: "dayplate.openLogFood")
                showsLogFood = true
            }
            guard networkMonitor.isConnected else { return }
            await offlineMealQueue.processPending(into: modelContext)
        }
        .task(id: offlineMealQueue.pendingCount) {
            guard offlineMealQueue.pendingCount > 0 else { return }
            while !Task.isCancelled && offlineMealQueue.pendingCount > 0 {
                if networkMonitor.isConnected {
                    await offlineMealQueue.processPending(into: modelContext)
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task { await offlineMealQueue.processPending(into: modelContext) }
        }
        .fullScreenCover(isPresented: $showsLogFood) {
            MealCaptureView(loggingDate: loggingDate)
        }
        .onOpenURL { url in
            guard url.scheme == "dayplate", url.host == "log" else { return }
            openMealCapture(for: .now)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayplateLogFood)) { _ in
            openMealCapture(for: .now)
        }
    }

    @ViewBuilder private var currentTabContent: some View {
        switch selectedTab {
        case .today:
            DayplateTodayView(onOpenProfile: { selectedTab = .you })
        case .history:
            DayplateHistoryView(selectedDate: $historySelectedDate)
        case .insights:
            DayplateInsightsView()
        case .you:
            SettingsView()
        }
    }

    private var bottomBar: some View {
        BottomBar(
            selection: $selectedTab,
            onLogMeal: { openMealCapture(for: selectedTab == .history ? historySelectedDate : .now) },
            onAddWater: selectedTab == .today && waterLoggingEnabled ? { addQuickWater() } : nil,
            quickWaterLabel: WaterDisplay.amount(defaultWaterML, unitSystem: unitSystem)
        )
        .background(JournalTheme.paper)
    }

    private func openMealCapture(for date: Date) {
        let calendar = Calendar.current
        let now = Date.now
        loggingDate = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: calendar.component(.minute, from: now),
            second: 0,
            of: calendar.startOfDay(for: date)
        ) ?? date
        showsLogFood = true
    }

    private func addQuickWater() {
        let now = Date.now
        let recentWater = waterLogs.last { Calendar.current.isDateInToday($0.timestamp) }
        if let recentWater, now.timeIntervalSince(recentWater.timestamp) <= 5 * 60 {
            recentWater.milliliters += defaultWaterML
            recentWater.timestamp = now
        } else {
            modelContext.insert(WaterLog(timestamp: now, milliliters: defaultWaterML))
        }
        try? modelContext.save()
    }
}

private struct BottomBar: View {
    @Binding var selection: AppTab
    let onLogMeal: () -> Void
    let onAddWater: (() -> Void)?
    let quickWaterLabel: String

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                tabButton("Today", icon: "circle.dotted", tab: .today)
                tabButton("History", icon: "calendar", tab: .history)
                tabButton("Insights", icon: "chart.bar.fill", tab: .insights)
                tabButton("You", icon: "person", tab: .you)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 7)
            .background(JournalTheme.paper)
            .overlay(alignment: .top) { Divider().opacity(0.35) }

            HStack(spacing: 12) {
                if let onAddWater {
                    Button(action: onAddWater) {
                        HStack(spacing: 7) {
                            Image(systemName: "drop.fill")
                            Text("+ \(quickWaterLabel)")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(JournalTheme.blue)
                        .frame(height: 52)
                        .padding(.horizontal, 17)
                        .background(JournalTheme.blue.opacity(0.13), in: Capsule())
                    }
                    .accessibilityLabel("Add \(quickWaterLabel) of water")
                }

                Button(action: onLogMeal) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.headline.bold())
                        Text("Log meal")
                            .font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 136, height: 52)
                    .background(JournalTheme.moss, in: Capsule())
                    .shadow(color: JournalTheme.ink.opacity(0.2), radius: 10, y: 4)
                }
                .accessibilityHint("Describe, speak, or photograph a meal, or repeat a meal")
            }
            .offset(y: -60)
        }
    }

    private func tabButton(_ title: String, icon: String, tab: AppTab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: selection == tab ? .semibold : .regular))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selection == tab ? JournalTheme.moss : JournalTheme.ink.opacity(0.55))
        }
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

extension Notification.Name {
    static let dayplateLogFood = Notification.Name("dayplate.logFood")
}

#Preview {
    ContentView()
        .modelContainer(for: [MealLog.self, MealItem.self, WaterLog.self, AppPreference.self], inMemory: true)
        .environmentObject(HealthKitStore())
        .environmentObject(OfflineMealQueueStore())
        .environmentObject(NetworkMonitor())
}
