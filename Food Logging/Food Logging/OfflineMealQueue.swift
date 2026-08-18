import Combine
import Foundation
import Network
import SwiftData

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "FoodLogging.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

@MainActor
final class OfflineMealQueueStore: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var isProcessing = false

    private let container: ModelContainer
    private let context: ModelContext

    init() {
        let schema = Schema([QueuedMeal.self])
        let configuration = ModelConfiguration("OfflineMealQueue", schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            context = ModelContext(container)
            reloadCount()
        } catch {
            fatalError("Unable to create the offline meal queue: \(error.localizedDescription)")
        }
    }

    func enqueue(description: String, mealPhotoData: Data?, nutritionLabelPhotoData: Data?, capturedAt: Date = .now) throws {
        let id = UUID()
        var storedPaths: [String] = []
        do {
            let mealPhotoPath = try OfflineMealPhotoStore.save(mealPhotoData, id: id, kind: "meal")
            if let mealPhotoPath { storedPaths.append(mealPhotoPath) }
            let nutritionLabelPhotoPath = try OfflineMealPhotoStore.save(nutritionLabelPhotoData, id: id, kind: "label")
            if let nutritionLabelPhotoPath { storedPaths.append(nutritionLabelPhotoPath) }

            context.insert(QueuedMeal(
                id: id,
                capturedAt: capturedAt,
                descriptionText: description,
                mealPhotoPath: mealPhotoPath,
                nutritionLabelPhotoPath: nutritionLabelPhotoPath
            ))
            try context.save()
            reloadCount()
        } catch {
            storedPaths.forEach(OfflineMealPhotoStore.remove)
            throw error
        }
    }

    func processPending(into mealContext: ModelContext) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false; reloadCount() }

        let descriptor = FetchDescriptor<QueuedMeal>(sortBy: [SortDescriptor(\.capturedAt)])
        guard let queuedMeals = try? context.fetch(descriptor) else { return }

        for queuedMeal in queuedMeals {
            do {
                let draft = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(
                        description: queuedMeal.descriptionText,
                        mealPhotoData: OfflineMealPhotoStore.data(at: queuedMeal.mealPhotoPath),
                        nutritionLabelPhotoData: OfflineMealPhotoStore.data(at: queuedMeal.nutritionLabelPhotoPath),
                        capturedAt: queuedMeal.capturedAt
                    )
                )
                mealContext.insert(MealLog(draft: draft, descriptionText: queuedMeal.descriptionText, timestamp: queuedMeal.capturedAt))
                try mealContext.save()
                OfflineMealPhotoStore.remove(queuedMeal.mealPhotoPath)
                OfflineMealPhotoStore.remove(queuedMeal.nutritionLabelPhotoPath)
                context.delete(queuedMeal)
                try context.save()
            } catch {
                queuedMeal.lastError = error.localizedDescription
                try? context.save()
            }
        }
    }

    func deleteAll() {
        let descriptor = FetchDescriptor<QueuedMeal>()
        guard let queuedMeals = try? context.fetch(descriptor) else { return }
        for queuedMeal in queuedMeals {
            OfflineMealPhotoStore.remove(queuedMeal.mealPhotoPath)
            OfflineMealPhotoStore.remove(queuedMeal.nutritionLabelPhotoPath)
            context.delete(queuedMeal)
        }
        try? context.save()
        reloadCount()
    }

    private func reloadCount() {
        pendingCount = (try? context.fetchCount(FetchDescriptor<QueuedMeal>())) ?? 0
    }
}

private enum OfflineMealPhotoStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("OfflineMealPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func save(_ data: Data?, id: UUID, kind: String) throws -> String? {
        guard let data else { return nil }
        let url = directory.appendingPathComponent("\(id.uuidString)-\(kind).jpg")
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url.path
    }

    static func data(at path: String?) -> Data? {
        guard let path else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func remove(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension MealLog {
    convenience init(draft: MealDraft, descriptionText: String, timestamp: Date = .now) {
        self.init(
            timestamp: timestamp,
            title: draft.title,
            descriptionText: descriptionText,
            calories: draft.calories,
            carbohydrates: draft.carbohydrates,
            protein: draft.protein,
            fat: draft.fat,
            fiber: draft.fiber,
            calcium: draft.calcium,
            iron: draft.iron,
            magnesium: draft.magnesium,
            potassium: draft.potassium,
            sodium: draft.sodium,
            vitaminD: draft.vitaminD,
            assumptions: draft.assumptions,
            items: draft.foods.map { MealItem(canonicalName: $0.name, portion: $0.portion) }
        )
    }
}
