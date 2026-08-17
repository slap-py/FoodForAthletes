import Foundation

/// A transient request. Neither image is written to SwiftData or the photo library.
struct MealAnalysisInput {
    let description: String
    let mealPhotoData: Data?
    let nutritionLabelPhotoData: Data?
    let capturedAt: Date
    let timeZoneIdentifier: String

    init(
        description: String, mealPhotoData: Data?, nutritionLabelPhotoData: Data?, capturedAt: Date = .now, timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.description = description
        self.mealPhotoData = mealPhotoData
        self.nutritionLabelPhotoData = nutritionLabelPhotoData
        self.capturedAt = capturedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

enum MealAnalysisError: LocalizedError {
    case needsTextOrPhoto
    case directAnalysisKeysRequired
    case noRecognizedFood
    case malformedServiceResponse

    var errorDescription: String? {
        switch self {
        case .needsTextOrPhoto:
            return "Add a description, a meal photo, or a nutrition-label photo to analyze a meal."
        case .directAnalysisKeysRequired:
            return "Add your OpenAI and USDA FoodData Central API keys in Settings to analyze photos directly from this iPhone."
        case .noRecognizedFood:
            return "I couldn’t match foods from that description. Try naming the main foods and portions, or add the nutrition-label photo."
        case .malformedServiceResponse:
            return "The food analysis service returned an unreadable meal estimate. Please try again."
        }
    }
}

/// Coordinates direct, on-device-originated analysis. The iPhone sends inputs to
/// OpenAI and USDA itself; keys stay in this device's Keychain.
struct MealAnalysisService {
    static let shared = MealAnalysisService()

    func analyze(_ input: MealAnalysisInput) async throws -> MealDraft {
        let trimmedDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty || input.mealPhotoData != nil || input.nutritionLabelPhotoData != nil else {
            throw MealAnalysisError.needsTextOrPhoto
        }

        if let openAIKey = APIKeyStore.value(for: .openAI),
           let foodDataKey = APIKeyStore.value(for: .foodDataCentral),
           !openAIKey.isEmpty, !foodDataKey.isEmpty {
            return try await DirectMealAnalysis(openAIKey: openAIKey, foodDataKey: foodDataKey).analyze(input)
        }
        if input.mealPhotoData != nil || input.nutritionLabelPhotoData != nil { throw MealAnalysisError.directAnalysisKeysRequired }
        guard !trimmedDescription.isEmpty else { throw MealAnalysisError.needsTextOrPhoto }
        return try LocalUSDACatalog.draft(for: trimmedDescription)
    }
}

private struct Nutrients {
    var calories: Double = 0
    var carbohydrates: Double = 0
    var protein: Double = 0
    var fat: Double = 0
    var fiber: Double = 0

    static func + (lhs: Nutrients, rhs: Nutrients) -> Nutrients {
        Nutrients(calories: lhs.calories + rhs.calories, carbohydrates: lhs.carbohydrates + rhs.carbohydrates, protein: lhs.protein + rhs.protein, fat: lhs.fat + rhs.fat, fiber: lhs.fiber + rhs.fiber)
    }
}

private struct CatalogFood {
    let name: String
    let aliases: [String]
    let portion: String
    let nutrients: Nutrients
}

private enum LocalUSDACatalog {
    // Curated per-common-serving snapshots based on USDA Foundation Foods and FNDDS.
    // The remote catalog is intentionally broader; this keeps useful private/offline logging.
    static let foods: [CatalogFood] = [
        .init(name: "Chicken breast", aliases: ["chicken breast", "chicken"], portion: "3 oz cooked", nutrients: .init(calories: 128, carbohydrates: 0, protein: 26, fat: 2.7, fiber: 0)),
        .init(name: "Salmon", aliases: ["salmon"], portion: "3 oz cooked", nutrients: .init(calories: 177, carbohydrates: 0, protein: 19, fat: 11, fiber: 0)),
        .init(name: "Ground beef", aliases: ["ground beef", "beef", "steak"], portion: "3 oz cooked", nutrients: .init(calories: 180, carbohydrates: 0, protein: 22, fat: 10, fiber: 0)),
        .init(name: "Tofu", aliases: ["tofu"], portion: "½ cup", nutrients: .init(calories: 94, carbohydrates: 2.3, protein: 10, fat: 5.8, fiber: 1.2)),
        .init(name: "Egg", aliases: ["egg", "eggs"], portion: "1 large", nutrients: .init(calories: 72, carbohydrates: 0.4, protein: 6.3, fat: 4.8, fiber: 0)),
        .init(name: "Greek yogurt", aliases: ["greek yogurt"], portion: "¾ cup", nutrients: .init(calories: 130, carbohydrates: 7, protein: 17, fat: 4, fiber: 0)),
        .init(name: "Milk", aliases: ["milk"], portion: "1 cup", nutrients: .init(calories: 122, carbohydrates: 12, protein: 8, fat: 4.8, fiber: 0)),
        .init(name: "Rice", aliases: ["rice", "brown rice", "white rice"], portion: "1 cup cooked", nutrients: .init(calories: 205, carbohydrates: 45, protein: 4.3, fat: 0.4, fiber: 0.6)),
        .init(name: "Pasta", aliases: ["pasta", "spaghetti", "noodles"], portion: "1 cup cooked", nutrients: .init(calories: 221, carbohydrates: 43, protein: 8, fat: 1.3, fiber: 2.5)),
        .init(name: "Oatmeal", aliases: ["oatmeal", "oats"], portion: "1 cup cooked", nutrients: .init(calories: 166, carbohydrates: 28, protein: 5.9, fat: 3.6, fiber: 4)),
        .init(name: "Bread", aliases: ["bread", "toast"], portion: "1 slice", nutrients: .init(calories: 79, carbohydrates: 15, protein: 4, fat: 1, fiber: 1.2)),
        .init(name: "Tortilla", aliases: ["tortilla", "tortillas"], portion: "1 medium", nutrients: .init(calories: 140, carbohydrates: 24, protein: 4, fat: 3.5, fiber: 2)),
        .init(name: "Potato", aliases: ["potato", "potatoes"], portion: "1 medium", nutrients: .init(calories: 164, carbohydrates: 37, protein: 4.3, fat: 0.2, fiber: 4)),
        .init(name: "Sweet potato", aliases: ["sweet potato", "sweet potatoes"], portion: "1 medium", nutrients: .init(calories: 112, carbohydrates: 26, protein: 2, fat: 0.1, fiber: 3.9)),
        .init(name: "Black beans", aliases: ["black beans", "beans"], portion: "½ cup", nutrients: .init(calories: 114, carbohydrates: 20, protein: 7.6, fat: 0.5, fiber: 7.5)),
        .init(name: "Chickpeas", aliases: ["chickpeas", "garbanzo"], portion: "½ cup", nutrients: .init(calories: 134, carbohydrates: 22, protein: 7.3, fat: 2.1, fiber: 6.2)),
        .init(name: "Avocado", aliases: ["avocado"], portion: "½ avocado", nutrients: .init(calories: 120, carbohydrates: 6.4, protein: 1.5, fat: 11, fiber: 5)),
        .init(name: "Broccoli", aliases: ["broccoli"], portion: "1 cup", nutrients: .init(calories: 31, carbohydrates: 6, protein: 2.6, fat: 0.3, fiber: 2.4)),
        .init(name: "Mixed vegetables", aliases: ["vegetables", "veggies", "vegetable"], portion: "1 cup", nutrients: .init(calories: 80, carbohydrates: 16, protein: 4, fat: 0.6, fiber: 5)),
        .init(name: "Banana", aliases: ["banana", "bananas"], portion: "1 medium", nutrients: .init(calories: 105, carbohydrates: 27, protein: 1.3, fat: 0.4, fiber: 3.1)),
        .init(name: "Apple", aliases: ["apple", "apples"], portion: "1 medium", nutrients: .init(calories: 95, carbohydrates: 25, protein: 0.5, fat: 0.3, fiber: 4.4)),
        .init(name: "Berries", aliases: ["berries", "strawberries", "blueberries"], portion: "1 cup", nutrients: .init(calories: 70, carbohydrates: 17, protein: 1, fat: 0.5, fiber: 5)),
        .init(name: "Peanut butter", aliases: ["peanut butter", "pb"], portion: "2 tbsp", nutrients: .init(calories: 190, carbohydrates: 7, protein: 8, fat: 16, fiber: 2)),
        .init(name: "Cheese", aliases: ["cheese"], portion: "1 oz", nutrients: .init(calories: 114, carbohydrates: 0.4, protein: 7, fat: 9, fiber: 0)),
        .init(name: "Olive oil", aliases: ["olive oil", "oil"], portion: "1 tbsp", nutrients: .init(calories: 119, carbohydrates: 0, protein: 0, fat: 13.5, fiber: 0)),
        .init(name: "Protein shake", aliases: ["protein shake", "protein powder", "shake"], portion: "1 scoop", nutrients: .init(calories: 120, carbohydrates: 3, protein: 24, fat: 2, fiber: 1)),
        .init(name: "Pizza", aliases: ["pizza"], portion: "1 slice", nutrients: .init(calories: 285, carbohydrates: 36, protein: 12, fat: 10, fiber: 2.5)),
        .init(name: "Burger", aliases: ["burger", "hamburger"], portion: "1 burger", nutrients: .init(calories: 354, carbohydrates: 29, protein: 20, fat: 17, fiber: 1.5)),
        .init(name: "Burrito", aliases: ["burrito"], portion: "1 medium", nutrients: .init(calories: 550, carbohydrates: 65, protein: 24, fat: 22, fiber: 9)),
        .init(name: "Sandwich", aliases: ["sandwich"], portion: "1 sandwich", nutrients: .init(calories: 380, carbohydrates: 40, protein: 22, fat: 14, fiber: 4))
    ]

    static func draft(for description: String) throws -> MealDraft {
        let normalized = description.lowercased()
        let matches = foods.compactMap { food -> (CatalogFood, Double)? in
            guard let alias = food.aliases.sorted(by: { $0.count > $1.count }).first(where: { normalized.contains($0) }) else { return nil }
            return (food, multiplier(for: alias, in: normalized))
        }
        guard !matches.isEmpty else { throw MealAnalysisError.noRecognizedFood }
        let totals = matches.reduce(Nutrients()) { $0 + scaled($1.0.nutrients, by: $1.1) }
        let foods: [(name: String, portion: String)] = matches.map { food, amount in
            (food.name, amount == 1 ? food.portion : "\(display(amount)) × \(food.portion)")
        }
        let title = makeTitle(description, foods: foods.map(\.name))
        let hasPortion = description.range(of: #"\d"#, options: .regularExpression) != nil
        let assumption = hasPortion
            ? "Estimated from the foods and portions in your description using the local USDA-derived catalog."
            : "Estimated using common portions from the local USDA-derived catalog. Add amounts for a closer estimate."
        return MealDraft(title: title, calories: totals.calories, carbohydrates: totals.carbohydrates, protein: totals.protein, fat: totals.fat, fiber: totals.fiber, assumptions: assumption, foods: foods)
    }

    private static func multiplier(for alias: String, in text: String) -> Double {
        let escaped = NSRegularExpression.escapedPattern(for: alias)
        let patterns = [
            #"(\d+(?:\.\d+)?)\s*(?:cups?|tbsp|tablespoons?|scoops?|slices?|eggs?|oz|ounces?|medium|large)?\s+"# + escaped,
            escaped + #"\s*(?:,|:)?\s*(\d+(?:\.\d+)?)\s*(?:oz|ounces?|cups?|tbsp|tablespoons?)"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression),
               let quantityRange = text[range].range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
               let amount = Double(text[quantityRange]) {
                return min(max(amount, 0.25), 8)
            }
        }
        return 1
    }

    private static func scaled(_ nutrients: Nutrients, by amount: Double) -> Nutrients {
        Nutrients(calories: nutrients.calories * amount, carbohydrates: nutrients.carbohydrates * amount, protein: nutrients.protein * amount, fat: nutrients.fat * amount, fiber: nutrients.fiber * amount)
    }

    private static func display(_ amount: Double) -> String { amount.rounded() == amount ? String(Int(amount)) : String(format: "%.1f", amount) }

    private static func makeTitle(_ description: String, foods: [String]) -> String {
        let words = description.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? foods.prefix(2).joined(separator: " & ") : words.capitalized
    }
}
