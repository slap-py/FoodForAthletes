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
    /// Added in Dayplate 1.3 with a default so existing snapshots migrate in place.
    /// Historical totals remain authoritative and are never recalculated.
    var loggingMethodRaw: String = LoggingMethod.ai.rawValue
    var catalogVersion: String?

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
        loggingMethod: LoggingMethod = .ai,
        catalogVersion: String? = nil,
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
        self.loggingMethodRaw = loggingMethod.rawValue
        self.catalogVersion = catalogVersion
        self.items = items
    }

    var loggingMethod: LoggingMethod {
        get { LoggingMethod(rawValue: loggingMethodRaw) ?? .ai }
        set { loggingMethodRaw = newValue.rawValue }
    }
}

enum LoggingMethod: String, Codable, CaseIterable {
    case search, ai, repeatMeal = "repeat"
}

@Model
final class MealItem {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var portion: String = ""
    var quantity: Double = 1
    var catalogFoodID: String?
    var sourceRecordIDs: [String] = []
    var brandName: String?
    var sourceName: String?
    var meal: MealLog?

    init(
        canonicalName: String,
        portion: String,
        quantity: Double = 1,
        catalogFoodID: String? = nil,
        sourceRecordIDs: [String] = [],
        brandName: String? = nil,
        sourceName: String? = nil
    ) {
        self.canonicalName = canonicalName
        self.portion = portion
        self.quantity = quantity
        self.catalogFoodID = catalogFoodID
        self.sourceRecordIDs = sourceRecordIDs
        self.brandName = brandName
        self.sourceName = sourceName
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

/// Kept in a separate, device-local SwiftData store. Photo bytes stay in the
/// app's protected Application Support directory and are deleted after analysis.
@Model
final class QueuedMeal {
    @Attribute(.unique) var id: UUID = UUID()
    var capturedAt: Date = Date()
    var descriptionText: String = ""
    var mealPhotoPath: String?
    var nutritionLabelPhotoPath: String?
    /// Added with the unified three-photo meal capture flow. Legacy paths above
    /// remain so already queued meals can still be processed.
    var photoPaths: [String] = []
    var lastError: String?

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        descriptionText: String,
        mealPhotoPath: String? = nil,
        nutritionLabelPhotoPath: String? = nil,
        photoPaths: [String] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.descriptionText = descriptionText
        self.mealPhotoPath = mealPhotoPath
        self.nutritionLabelPhotoPath = nutritionLabelPhotoPath
        self.photoPaths = photoPaths
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
    var ingredientSources: [String: String] = [:]
    var loggingMethod: LoggingMethod = .ai
    var catalogItems: [CatalogMealItem] = []
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
        lhs.ingredientSources == rhs.ingredientSources &&
        lhs.foods.elementsEqual(rhs.foods, by: { $0.name == $1.name && $0.portion == $1.portion })
    }
}

struct CatalogMealItem: Equatable, Codable, Identifiable {
    var id: UUID = UUID()
    var food: CatalogFood
    var servingIndex: Int = 0
    var quantity: Double = 1

    var serving: CatalogServing { food.servings[min(max(servingIndex, 0), food.servings.count - 1)] }
    var displayPortion: String { quantity == 1 ? serving.label : "\(quantity.formatted(.number.precision(.fractionLength(0...2)))) × \(serving.label)" }
    var nutrients: CatalogNutrients { serving.nutrients.scaled(by: quantity) }
}
