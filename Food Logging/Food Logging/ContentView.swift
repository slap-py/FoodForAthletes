import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case today, history, settings
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var offlineMealQueue: OfflineMealQueueStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @State private var selectedTab: AppTab = .today
    @State private var showsLogFood = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("appLanguage") private var appLanguage = "system"

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
        Group {
            switch selectedTab {
            case .today: TodayView(onLogMeal: { showsLogFood = true })
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(selection: $selectedTab, onLogMeal: { showsLogFood = true })
                .background(JournalTheme.paper)
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
            MealCaptureView()
        }
        .onOpenURL { url in
            guard url.scheme == "dayplate", url.host == "log" else { return }
            showsLogFood = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayplateLogFood)) { _ in
            showsLogFood = true
        }
    }
}

private struct BottomBar: View {
    @Binding var selection: AppTab
    let onLogMeal: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                tabButton("Today", icon: "sun.max", tab: .today)
                tabButton("History", icon: "clock.arrow.circlepath", tab: .history)
                tabButton("Settings", icon: "slider.horizontal.3", tab: .settings)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 7)
            .background(JournalTheme.paper)
            .overlay(alignment: .top) { Divider().opacity(0.35) }

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
            .offset(y: -58)
            .accessibilityHint("Describe, speak, or photograph a meal, or repeat a meal")
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
