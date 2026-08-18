import Foundation

struct CatalogNutrients: Codable, Equatable {
    var calories: Double
    var carbohydrates: Double
    var protein: Double
    var fat: Double
    var fiber: Double
    var calcium: Double = 0
    var iron: Double = 0
    var magnesium: Double = 0
    var potassium: Double = 0
    var sodium: Double = 0
    var vitaminD: Double = 0

    func scaled(by quantity: Double) -> Self {
        .init(calories: calories * quantity, carbohydrates: carbohydrates * quantity, protein: protein * quantity, fat: fat * quantity, fiber: fiber * quantity, calcium: calcium * quantity, iron: iron * quantity, magnesium: magnesium * quantity, potassium: potassium * quantity, sodium: sodium * quantity, vitaminD: vitaminD * quantity)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(calories: lhs.calories + rhs.calories, carbohydrates: lhs.carbohydrates + rhs.carbohydrates, protein: lhs.protein + rhs.protein, fat: lhs.fat + rhs.fat, fiber: lhs.fiber + rhs.fiber, calcium: lhs.calcium + rhs.calcium, iron: lhs.iron + rhs.iron, magnesium: lhs.magnesium + rhs.magnesium, potassium: lhs.potassium + rhs.potassium, sodium: lhs.sodium + rhs.sodium, vitaminD: lhs.vitaminD + rhs.vitaminD)
    }

    static let zero = Self(calories: 0, carbohydrates: 0, protein: 0, fat: 0, fiber: 0)
}

struct CatalogServing: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var gramWeight: Double
    var nutrients: CatalogNutrients
}

struct CatalogProvenance: Codable, Equatable, Identifiable {
    var id: String { "\(source):\(sourceID)" }
    var source: String
    var sourceID: String
    var sourceDescription: String
    var importedAt: Date
}

struct CatalogFood: Codable, Equatable, Identifiable {
    var id: String
    var canonicalName: String
    var brandName: String?
    var searchAliases: [String]
    var servings: [CatalogServing]
    var provenance: [CatalogProvenance]
    var catalogVersion: String

    var displayName: String { canonicalName }
    var sourceSummary: String {
        let sources = Set(provenance.map(\.source)).sorted().joined(separator: " + ")
        return brandName.map { "\($0) · \(sources)" } ?? sources
    }
}

enum DayplateCatalog {
    static let version = "dayplate-usda-2026.08-v1"

    /// A small checked-in slice of the versioned catalog keeps tests deterministic.
    /// Production builds can replace this snapshot from the Dayplate catalog endpoint.
    static let foods: [CatalogFood] = [
        food("usda:chicken-breast", "Chicken breast, roasted", aliases: ["chicken", "chicken breast"], serving: "3 oz cooked", grams: 85, nutrients: .init(calories: 140, carbohydrates: 0, protein: 26, fat: 3, fiber: 0), ids: ["171077", "746758"]),
        food("usda:brown-rice", "Brown rice, cooked", aliases: ["rice", "brown rice"], serving: "1 cup cooked", grams: 195, nutrients: .init(calories: 218, carbohydrates: 46, protein: 4.5, fat: 1.6, fiber: 3.5), ids: ["168875"]),
        food("usda:banana", "Banana, raw", aliases: ["banana"], serving: "1 medium", grams: 118, nutrients: .init(calories: 105, carbohydrates: 27, protein: 1.3, fat: 0.4, fiber: 3.1), ids: ["173944", "1105314"]),
        food("usda:egg", "Egg, whole, cooked", aliases: ["egg", "eggs"], serving: "1 large", grams: 50, nutrients: .init(calories: 78, carbohydrates: 0.6, protein: 6.3, fat: 5.3, fiber: 0), ids: ["171287"]),
        food("usda:avocado", "Avocado, raw", aliases: ["avocado"], serving: "½ avocado", grams: 75, nutrients: .init(calories: 120, carbohydrates: 6.4, protein: 1.5, fat: 11, fiber: 5), ids: ["171705"]),
        food("usda:greek-yogurt", "Greek yogurt, plain", aliases: ["yogurt", "greek yogurt"], serving: "¾ cup", grams: 170, nutrients: .init(calories: 130, carbohydrates: 7, protein: 17, fat: 4, fiber: 0), ids: ["2259793"]),
        branded("brand:cheerios-original", "Cheerios Original Cereal", brand: "General Mills", aliases: ["cheerios", "cereal"], serving: "1½ cups", grams: 39, nutrients: .init(calories: 140, carbohydrates: 29, protein: 5, fat: 2.5, fiber: 4, sodium: 190), id: "2340765"),
        branded("brand:clif-chocolate-chip", "CLIF BAR Chocolate Chip", brand: "Clif Bar", aliases: ["clif bar", "energy bar", "chocolate chip bar"], serving: "1 bar", grams: 68, nutrients: .init(calories: 250, carbohydrates: 43, protein: 10, fat: 5, fiber: 4, sodium: 250), id: "2140978"),
        branded("brand:fage-plain-2", "Total 2% Plain Greek Yogurt", brand: "Fage", aliases: ["fage", "greek yogurt", "yogurt"], serving: "¾ cup", grams: 170, nutrients: .init(calories: 120, carbohydrates: 5, protein: 17, fat: 4, fiber: 0, sodium: 55), id: "2644801")
    ]

    static func search(_ query: String) -> [CatalogFood] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        return foods.compactMap { food -> (CatalogFood, Int)? in
            let keys = [food.canonicalName, food.brandName].compactMap { $0 }.map { normalize($0) } + food.searchAliases.map { normalize($0) }
            if keys.contains(needle) { return (food, 0) }
            if keys.contains(where: { $0.hasPrefix(needle) }) { return (food, 1) }
            let needleTokens = Set(needle.split(separator: " ").map(String.init))
            let overlap = keys.map { Set($0.split(separator: " ").map(String.init)).intersection(needleTokens).count }.max() ?? 0
            return overlap > 0 ? (food, 10 - overlap) : nil
        }
        .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.canonicalName < rhs.0.canonicalName : lhs.1 < rhs.1 }
        .map(\.0)
    }

    static func draft(items: [CatalogMealItem], title: String = "Meal") -> MealDraft {
        let totals = items.reduce(CatalogNutrients.zero) { $0 + $1.nutrients }
        return MealDraft(title: title, calories: totals.calories, carbohydrates: totals.carbohydrates, protein: totals.protein, fat: totals.fat, fiber: totals.fiber, calcium: totals.calcium, iron: totals.iron, magnesium: totals.magnesium, potassium: totals.potassium, sodium: totals.sodium, vitaminD: totals.vitaminD, assumptions: "Calculated from catalog servings. Source records are retained for traceability.", foods: items.map { ($0.food.canonicalName, $0.displayPortion) }, loggingMethod: .search, catalogItems: items)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func food(_ id: String, _ name: String, aliases: [String], serving: String, grams: Double, nutrients: CatalogNutrients, ids: [String]) -> CatalogFood {
        .init(id: id, canonicalName: name, searchAliases: aliases, servings: [.init(id: "default", label: serving, gramWeight: grams, nutrients: nutrients)], provenance: ids.map { .init(source: "USDA FoodData Central", sourceID: $0, sourceDescription: name, importedAt: Date(timeIntervalSince1970: 1_775_433_600)) }, catalogVersion: version)
    }

    private static func branded(_ id: String, _ name: String, brand: String, aliases: [String], serving: String, grams: Double, nutrients: CatalogNutrients, id sourceID: String) -> CatalogFood {
        .init(id: id, canonicalName: name, brandName: brand, searchAliases: aliases, servings: [.init(id: "default", label: serving, gramWeight: grams, nutrients: nutrients)], provenance: [.init(source: "USDA Branded Food Products", sourceID: sourceID, sourceDescription: name, importedAt: Date(timeIntervalSince1970: 1_775_433_600))], catalogVersion: version)
    }
}
