import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case today, history, settings
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .today
    @State private var showsMealCapture = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .today: TodayView(onLogMeal: { showsMealCapture = true })
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomBar(selection: $selectedTab, onLogMeal: { showsMealCapture = true })
        }
        .background(JournalTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showsMealCapture) {
            MealCaptureView()
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
            .accessibilityHint("Opens meal description and photo capture")
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

#Preview {
    ContentView()
        .modelContainer(for: [MealLog.self, MealItem.self, WaterLog.self, AppPreference.self], inMemory: true)
}
