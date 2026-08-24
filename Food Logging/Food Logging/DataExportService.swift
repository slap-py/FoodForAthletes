import Foundation

enum DataExportService {
    struct Export: Codable {
        let exportedAt: Date
        let formatVersion: Int
        let profileName: String
        let meals: [Meal]
        let water: [Water]
    }

    struct Meal: Codable {
        let id: UUID
        let timestamp: Date
        let title: String
        let description: String
        let analysisStatus: String
        let calories: Double
        let carbohydrates: Double
        let protein: Double
        let fat: Double
        let fiber: Double
        let calcium: Double
        let iron: Double
        let magnesium: Double
        let potassium: Double
        let sodium: Double
        let vitaminD: Double
        let assumptions: String
        let loggingMethod: String
        let analysisVersion: String?
        let items: [Item]
    }

    struct Item: Codable {
        let name: String
        let portion: String
        let quantity: Double
        let sourceTier: String?
        let sourceName: String?
    }

    struct Water: Codable {
        let id: UUID
        let timestamp: Date
        let milliliters: Double
    }

    static func generate(meals: [MealLog], water: [WaterLog], profileName: String, profilePhotoPath: String) throws -> [URL] {
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dayplate Exports", isDirectory: true)
            .appendingPathComponent("Dayplate Export \(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let export = Export(
            exportedAt: .now,
            formatVersion: 1,
            profileName: profileName,
            meals: meals.sorted { $0.timestamp < $1.timestamp }.map { meal in
                Meal(
                    id: meal.id,
                    timestamp: meal.timestamp,
                    title: meal.title,
                    description: meal.descriptionText,
                    analysisStatus: meal.analysisStatus.rawValue,
                    calories: meal.calories,
                    carbohydrates: meal.carbohydrates,
                    protein: meal.protein,
                    fat: meal.fat,
                    fiber: meal.fiber,
                    calcium: meal.calcium,
                    iron: meal.iron,
                    magnesium: meal.magnesium,
                    potassium: meal.potassium,
                    sodium: meal.sodium,
                    vitaminD: meal.vitaminD,
                    assumptions: meal.assumptions,
                    loggingMethod: meal.loggingMethod.rawValue,
                    analysisVersion: meal.catalogVersion,
                    items: (meal.items ?? []).map {
                        Item(name: $0.canonicalName, portion: $0.portion, quantity: $0.quantity, sourceTier: $0.sourceTier?.rawValue, sourceName: $0.sourceName)
                    }
                )
            },
            water: water.sorted { $0.timestamp < $1.timestamp }.map { Water(id: $0.id, timestamp: $0.timestamp, milliliters: $0.milliliters) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonURL = root.appendingPathComponent("dayplate-data.json")
        try encoder.encode(export).write(to: jsonURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        let mealsURL = root.appendingPathComponent("meals.csv")
        try write(mealCSV(export.meals), to: mealsURL)
        let itemsURL = root.appendingPathComponent("meal-items.csv")
        try write(itemCSV(export.meals), to: itemsURL)
        let waterURL = root.appendingPathComponent("water.csv")
        try write(waterCSV(export.water), to: waterURL)
        var urls = [jsonURL, mealsURL, itemsURL, waterURL]
        if let sourceURL = ProfilePhotoStore.url(for: profilePhotoPath), FileManager.default.fileExists(atPath: sourceURL.path) {
            let photoURL = root.appendingPathComponent("profile-photo.jpg")
            try FileManager.default.copyItem(at: sourceURL, to: photoURL)
            urls.append(photoURL)
        }
        return urls
    }

    private static func mealCSV(_ meals: [Meal]) -> String {
        let header = "id,timestamp,title,description,analysis_status,calories_kcal,carbohydrates_g,protein_g,fat_g,fiber_g,calcium_mg,iron_mg,magnesium_mg,potassium_mg,sodium_mg,vitamin_d_mcg,assumptions,logging_method,analysis_version"
        return ([header] + meals.map {
            row([$0.id.uuidString, iso($0.timestamp), $0.title, $0.description, $0.analysisStatus, number($0.calories), number($0.carbohydrates), number($0.protein), number($0.fat), number($0.fiber), number($0.calcium), number($0.iron), number($0.magnesium), number($0.potassium), number($0.sodium), number($0.vitaminD), $0.assumptions, $0.loggingMethod, $0.analysisVersion ?? ""])
        }).joined(separator: "\n") + "\n"
    }

    private static func itemCSV(_ meals: [Meal]) -> String {
        let header = "meal_id,meal_timestamp,name,portion,quantity,source_tier,source_name"
        let rows = meals.flatMap { meal in
            meal.items.map { row([meal.id.uuidString, iso(meal.timestamp), $0.name, $0.portion, number($0.quantity), $0.sourceTier ?? "", $0.sourceName ?? ""]) }
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func waterCSV(_ water: [Water]) -> String {
        let header = "id,timestamp,milliliters"
        return ([header] + water.map { row([$0.id.uuidString, iso($0.timestamp), number($0.milliliters)]) }).joined(separator: "\n") + "\n"
    }

    nonisolated private static func row(_ values: [String]) -> String { values.map { csv($0) }.joined(separator: ",") }
    nonisolated private static func csv(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    nonisolated private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    nonisolated private static func number(_ value: Double) -> String { String(format: "%.4f", value) }
    nonisolated private static func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
