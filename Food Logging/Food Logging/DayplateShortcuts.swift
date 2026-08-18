import AppIntents
import Foundation

struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log food"
    static let description = IntentDescription("Open Dayplate’s logging-method picker.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "dayplate.openLogFood")
        NotificationCenter.default.post(name: .dayplateLogFood, object: nil)
        return .result()
    }
}

struct DayplateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogFoodIntent(),
            phrases: [
                "Log food in \(.applicationName)",
                "Open \(.applicationName) food logging"
            ],
            shortTitle: "Log food",
            systemImageName: "fork.knife"
        )
    }
}
