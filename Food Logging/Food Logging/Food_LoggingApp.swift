//
//  Food_LoggingApp.swift
//  Food Logging
//
//  Created by Kai Bergman on 8/16/26.
//

import SwiftUI
import SwiftData

@main
struct Food_LoggingApp: App {
    @StateObject private var healthStore = HealthKitStore()
    @StateObject private var offlineMealQueue = OfflineMealQueueStore()
    @StateObject private var networkMonitor = NetworkMonitor()
    private let modelContainer: ModelContainer = {
        let schema = Schema([MealLog.self, MealItem.self, WaterLog.self, AppPreference.self])
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let testConfiguration = ModelConfiguration(
                "FoodForAthletesUITests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: schema, configurations: [testConfiguration])
        }
        let cloud = ModelConfiguration(
            "FoodForAthletes",
            schema: schema,
            cloudKitDatabase: .private("iCloud.kaibergman.Food-Logging")
        )
        do {
            return try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            // Keep the journal usable offline or before the iCloud container is provisioned.
            let local = ModelConfiguration("FoodForAthletesLocal", schema: schema, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [local])
            } catch {
                fatalError("Unable to create the private journal store: \(error.localizedDescription)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(JournalTheme.moss)
                .environmentObject(healthStore)
                .environmentObject(offlineMealQueue)
                .environmentObject(networkMonitor)
                .environment(\.colorScheme, .light)
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
