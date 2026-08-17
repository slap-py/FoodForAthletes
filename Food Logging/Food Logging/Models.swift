import Foundation
import SwiftData

@Model
final class MealLog {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var title: String = ""
    var descriptionText: String = ""
    var calories: Double = 0
    var carbohydrates: Double = 0
    var protein: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var calcium: Double = 0
    var iron: Double = 0
    var magnesium: Double = 0
    var potassium: Double = 0
    var sodium: Double = 0
    var vitaminD: Double = 0
    var assumptions: String = ""
    var sourceMealID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \MealItem.meal)
    var items: [MealItem]? = []

    init(
        timestamp: Date = .now,
        title: String,
        descriptionText: String,
        calories: Double,
        carbohydrates: Double,
        protein: Double,
        fat: Double,
        fiber: Double,
        calcium: Double = 0,
        iron: Double = 0,
        magnesium: Double = 0,
        potassium: Double = 0,
        sodium: Double = 0,
        vitaminD: Double = 0,
        assumptions: String,
        sourceMealID: UUID? = nil,
        items: [MealItem] = []
    ) {
        self.timestamp = timestamp
        self.title = title
        self.descriptionText = descriptionText
        self.calories = calories
        self.carbohydrates = carbohydrates
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calcium = calcium
        self.iron = iron
        self.magnesium = magnesium
        self.potassium = potassium
        self.sodium = sodium
        self.vitaminD = vitaminD
        self.assumptions = assumptions
        self.sourceMealID = sourceMealID
        self.items = items
    }
}

@Model
final class MealItem {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var portion: String = ""
    var meal: MealLog?

    init(canonicalName: String, portion: String) {
        self.canonicalName = canonicalName
        self.portion = portion
    }
}

@Model
final class WaterLog {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var milliliters: Double = 240

    init(timestamp: Date = .now, milliliters: Double) {
        self.timestamp = timestamp
        self.milliliters = milliliters
    }
}

@Model
final class AppPreference {
    var id: UUID = UUID()
    var updatedAt: Date = Date()
    var unitSystem: String = "us"
    var defaultWaterMilliliters: Double = 240

    init() {}
}

struct MealDraft: Equatable {
    var title: String
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
    var assumptions: String
    var foods: [(name: String, portion: String)]
    var analysisVersion: String = "local-catalog-v1"
    var catalogVersion: String = "USDA Foundation Foods + FNDDS fallback v1"

    static func == (lhs: MealDraft, rhs: MealDraft) -> Bool {
        lhs.title == rhs.title &&
        lhs.calories == rhs.calories &&
        lhs.carbohydrates == rhs.carbohydrates &&
        lhs.protein == rhs.protein &&
        lhs.fat == rhs.fat &&
        lhs.fiber == rhs.fiber &&
        lhs.calcium == rhs.calcium &&
        lhs.iron == rhs.iron &&
        lhs.magnesium == rhs.magnesium &&
        lhs.potassium == rhs.potassium &&
        lhs.sodium == rhs.sodium &&
        lhs.vitaminD == rhs.vitaminD &&
        lhs.foods.elementsEqual(rhs.foods, by: { $0.name == $1.name && $0.portion == $1.portion })
    }
}
