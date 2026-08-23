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

    func enqueue(
        description: String,
        photoData: [Data],
        identifiedFoods: [String] = [],
        clarificationAnswers: [String: String] = [:],
        clarificationRound: Int = 0,
        capturedAt: Date = .now
    ) throws {
        let id = UUID()
        var storedPaths: [String] = []
        do {
            let photoPaths = try photoData.prefix(3).enumerated().compactMap { index, data in
                let path = try OfflineMealPhotoStore.save(data, id: id, kind: "photo-\(index)")
                if let path { storedPaths.append(path) }
                return path
            }

            context.insert(QueuedMeal(
                id: id,
                capturedAt: capturedAt,
                descriptionText: description,
                photoPaths: photoPaths,
                identifiedFoods: identifiedFoods,
                clarificationAnswersData: try JSONEncoder().encode(clarificationAnswers),
                clarificationRound: clarificationRound
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
            guard queuedMeal.attemptCount < 3 else { continue }
            do {
                let draft = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(
                        description: queuedMeal.descriptionText,
                        photoData: queuedMeal.allPhotoPaths.compactMap(OfflineMealPhotoStore.data),
                        identifiedFoods: queuedMeal.identifiedFoods,
                        capturedAt: queuedMeal.capturedAt,
                        clarificationAnswers: queuedMeal.clarificationAnswers,
                        clarificationRound: queuedMeal.clarificationRound
                    )
                )
                mealContext.insert(MealLog(draft: draft, descriptionText: queuedMeal.descriptionText, timestamp: queuedMeal.capturedAt))
                try mealContext.save()
                queuedMeal.allPhotoPaths.forEach(OfflineMealPhotoStore.remove)
                context.delete(queuedMeal)
                try context.save()
            } catch {
                queuedMeal.attemptCount += 1
                queuedMeal.lastError = error.localizedDescription
                try? context.save()
            }
        }
    }

    func deleteAll() {
        let descriptor = FetchDescriptor<QueuedMeal>()
        guard let queuedMeals = try? context.fetch(descriptor) else { return }
        for queuedMeal in queuedMeals {
            queuedMeal.allPhotoPaths.forEach(OfflineMealPhotoStore.remove)
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
            items: draft.foods.map { MealItem(canonicalName: $0.name, portion: $0.portion, sourceName: draft.ingredientSources[$0.name]) }
        )
    }
}

private extension QueuedMeal {
    var allPhotoPaths: [String] { [mealPhotoPath, nutritionLabelPhotoPath].compactMap { $0 } + photoPaths }
    var clarificationAnswers: [String: String] {
        guard let clarificationAnswersData else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: clarificationAnswersData)) ?? [:]
    }
}
