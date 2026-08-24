import Combine
import CryptoKit
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
        capturedAt: Date = .now,
        targetMealID: UUID? = nil
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
                clarificationRound: clarificationRound,
                targetMealID: targetMealID
            ))
            try context.save()
            reloadCount()
        } catch {
            storedPaths.forEach(OfflineMealPhotoStore.remove)
            throw error
        }
    }

    func processPending(into mealContext: ModelContext, networkAvailable: Bool = true) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false; reloadCount() }

        let descriptor = FetchDescriptor<QueuedMeal>(sortBy: [SortDescriptor(\.capturedAt)])
        guard let queuedMeals = try? context.fetch(descriptor) else { return }

        for queuedMeal in queuedMeals {
            guard queuedMeal.attemptCount < 3 else { continue }
            if queuedMeal.allPhotoPaths.isEmpty,
               let cached = MealAnalysisDiskCache.shared.value(for: queuedMeal.cacheKey) {
                finish(queuedMeal, with: cached, in: mealContext)
                continue
            }
            guard networkAvailable else { continue }
            do {
                let draft = try await MealAnalysisService.shared.analyze(
                    MealAnalysisInput(
                        description: queuedMeal.descriptionText,
                        photoData: queuedMeal.allPhotoPaths.compactMap(OfflineMealPhotoStore.data),
                        identifiedFoods: queuedMeal.identifiedFoods,
                        capturedAt: queuedMeal.capturedAt,
                        allowsClarification: true,
                        clarificationAnswers: queuedMeal.clarificationAnswers,
                        clarificationRound: queuedMeal.clarificationRound
                    )
                )
                if queuedMeal.allPhotoPaths.isEmpty {
                    MealAnalysisDiskCache.shared.insert(draft, for: queuedMeal.cacheKey)
                }
                finish(queuedMeal, with: draft, in: mealContext)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                queuedMeal.attemptCount = shouldRetryInBackground(error) || shouldRetryServiceRequest(error) ? queuedMeal.attemptCount + 1 : 3
                queuedMeal.lastError = message
                try? context.save()
                if queuedMeal.attemptCount >= 3,
                   let target = fetchMeal(id: queuedMeal.targetMealID, in: mealContext) {
                    target.analysisStatus = .failed
                    target.analysisError = message
                    try? mealContext.save()
                }
            }
        }
    }

    func retry(meal: MealLog, in mealContext: ModelContext) {
        let id = meal.id
        let descriptor = FetchDescriptor<QueuedMeal>(predicate: #Predicate { $0.targetMealID == id })
        guard let queued = try? context.fetch(descriptor).first else { return }
        queued.attemptCount = 0
        queued.lastError = nil
        meal.analysisStatus = .pending
        meal.analysisError = nil
        try? context.save()
        try? mealContext.save()
        reloadCount()
    }

    func retryAll(in mealContext: ModelContext) {
        let descriptor = FetchDescriptor<QueuedMeal>()
        guard let queuedMeals = try? context.fetch(descriptor) else { return }
        for queued in queuedMeals {
            queued.attemptCount = 0
            queued.lastError = nil
            if let meal = fetchMeal(id: queued.targetMealID, in: mealContext) {
                meal.analysisStatus = .pending
                meal.analysisError = nil
            }
        }
        try? context.save()
        try? mealContext.save()
        reloadCount()
    }

    func answer(
        _ option: MealClarification.Option,
        questionID: String,
        for meal: MealLog,
        in mealContext: ModelContext
    ) throws {
        let id = meal.id
        let existingDescriptor = FetchDescriptor<QueuedMeal>(predicate: #Predicate { $0.targetMealID == id })
        if let existing = try context.fetch(existingDescriptor).first {
            context.delete(existing)
        }
        let answers = [questionID: option.value]
        meal.analysisStatus = .pending
        meal.analysisError = nil
        meal.clarificationSuggestions = []
        try mealContext.save()
        try enqueue(
            description: meal.descriptionText,
            photoData: [],
            clarificationAnswers: answers,
            clarificationRound: 1,
            capturedAt: meal.timestamp,
            targetMealID: meal.id
        )
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

    /// Removes both the visible failed placeholder and its protected queued
    /// photos. Queue and meal data live in separate stores, so this cleanup is
    /// intentionally centralized rather than relying on the meal relationship.
    func delete(meal: MealLog, in mealContext: ModelContext) {
        let id = meal.id
        let descriptor = FetchDescriptor<QueuedMeal>(predicate: #Predicate { $0.targetMealID == id })
        if let queuedMeals = try? context.fetch(descriptor) {
            for queuedMeal in queuedMeals {
                queuedMeal.allPhotoPaths.forEach(OfflineMealPhotoStore.remove)
                context.delete(queuedMeal)
            }
            try? context.save()
        }
        mealContext.delete(meal)
        try? mealContext.save()
        reloadCount()
    }

    private func reloadCount() {
        pendingCount = (try? context.fetchCount(FetchDescriptor<QueuedMeal>())) ?? 0
    }

    private func finish(_ queuedMeal: QueuedMeal, with draft: MealDraft, in mealContext: ModelContext) {
        if let target = fetchMeal(id: queuedMeal.targetMealID, in: mealContext) {
            (target.items ?? []).forEach(mealContext.delete)
            target.apply(draft: draft, descriptionText: queuedMeal.descriptionText)
        } else if queuedMeal.targetMealID == nil {
            mealContext.insert(MealLog(draft: draft, descriptionText: queuedMeal.descriptionText, timestamp: queuedMeal.capturedAt))
        } else {
            queuedMeal.allPhotoPaths.forEach(OfflineMealPhotoStore.remove)
            context.delete(queuedMeal)
            try? context.save()
            return
        }
        do {
            try mealContext.save()
            queuedMeal.allPhotoPaths.forEach(OfflineMealPhotoStore.remove)
            context.delete(queuedMeal)
            try context.save()
        } catch {
            queuedMeal.lastError = error.localizedDescription
            try? context.save()
        }
    }

    private func fetchMeal(id: UUID?, in mealContext: ModelContext) -> MealLog? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<MealLog>(predicate: #Predicate { $0.id == id })
        return try? mealContext.fetch(descriptor).first
    }

    private func shouldRetryInBackground(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ].contains(code)
    }

    private func shouldRetryServiceRequest(_ error: Error) -> Bool {
        guard let serviceError = error as? DayplateServiceError,
              case let .server(message) = serviceError else { return false }
        return message == "analysis_timed_out"
            || message == "service_unavailable"
            || message.localizedCaseInsensitiveContains("temporarily unavailable")
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
            clarificationSuggestionsData: try? JSONEncoder().encode(draft.clarifications),
            items: draft.foods.map(MealItem.init(food:))
        )
    }

    func apply(draft: MealDraft, descriptionText: String) {
        title = draft.title
        self.descriptionText = descriptionText
        calories = draft.calories
        carbohydrates = draft.carbohydrates
        protein = draft.protein
        fat = draft.fat
        fiber = draft.fiber
        calcium = draft.calcium
        iron = draft.iron
        magnesium = draft.magnesium
        potassium = draft.potassium
        sodium = draft.sodium
        vitaminD = draft.vitaminD
        assumptions = draft.assumptions
        catalogVersion = draft.catalogVersion
        analysisStatus = .resolved
        analysisError = nil
        clarificationSuggestions = draft.clarifications
        items = draft.foods.map {
            let item = MealItem(food: $0)
            item.meal = self
            return item
        }
    }
}

extension MealItem {
    convenience init(food: MealDraftFood) {
        self.init(
            canonicalName: food.name,
            portion: food.portion,
            sourceName: food.sourceName,
            sourceTier: food.sourceTier,
            calories: food.calories,
            carbohydrates: food.carbohydrates,
            protein: food.protein,
            fat: food.fat
        )
    }
}

private extension QueuedMeal {
    var allPhotoPaths: [String] { [mealPhotoPath, nutritionLabelPhotoPath].compactMap { $0 } + photoPaths }
    var clarificationAnswers: [String: String] {
        guard let clarificationAnswersData else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: clarificationAnswersData)) ?? [:]
    }

    var cacheKey: String {
        MealAnalysisDiskCache.key(
            description: descriptionText,
            identifiedFoods: identifiedFoods,
            clarificationAnswers: clarificationAnswers,
            clarificationRound: clarificationRound
        )
    }
}

private final class MealAnalysisDiskCache {
    struct Entry: Codable {
        let draft: MealDraft
        let expiresAt: Date
        let lastAccessedAt: Date
    }

    static let shared = MealAnalysisDiskCache()
    private let url: URL
    private var entries: [String: Entry]
    private let maximumEntries = 100
    private let lifetime: TimeInterval = 180 * 24 * 60 * 60

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("MealAnalysisCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("cache.json")
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        sweep()
    }

    func value(for key: String) -> MealDraft? {
        guard let entry = entries[key], entry.expiresAt > .now else {
            entries.removeValue(forKey: key)
            persist()
            return nil
        }
        entries[key] = Entry(draft: entry.draft, expiresAt: entry.expiresAt, lastAccessedAt: .now)
        persist()
        return entry.draft
    }

    func insert(_ draft: MealDraft, for key: String) {
        entries[key] = Entry(draft: draft, expiresAt: .now.addingTimeInterval(lifetime), lastAccessedAt: .now)
        sweep()
        persist()
    }

    static func key(description: String, identifiedFoods: [String], clarificationAnswers: [String: String], clarificationRound: Int) -> String {
        let normalized = [
            description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            identifiedFoods.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.sorted().joined(separator: "|"),
            clarificationAnswers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|"),
            String(clarificationRound)
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func sweep() {
        entries = entries.filter { $0.value.expiresAt > .now }
        if entries.count > maximumEntries {
            for key in entries.sorted(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }).prefix(entries.count - maximumEntries).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
