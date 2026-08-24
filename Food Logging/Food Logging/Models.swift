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
    /// Analysis lifecycle is separate from how the meal was logged. Existing
    /// meals default to resolved during lightweight migration.
    var analysisStatusRaw: String = MealAnalysisStatus.resolved.rawValue
    var analysisError: String?
    var clarificationSuggestionsData: Data?

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
        analysisStatus: MealAnalysisStatus = .resolved,
        analysisError: String? = nil,
        clarificationSuggestionsData: Data? = nil,
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
        self.analysisStatusRaw = analysisStatus.rawValue
        self.analysisError = analysisError
        self.clarificationSuggestionsData = clarificationSuggestionsData
        self.items = items
    }

    var loggingMethod: LoggingMethod {
        get { LoggingMethod(rawValue: loggingMethodRaw) ?? .ai }
        set { loggingMethodRaw = newValue.rawValue }
    }

    var analysisStatus: MealAnalysisStatus {
        get { MealAnalysisStatus(rawValue: analysisStatusRaw) ?? .resolved }
        set { analysisStatusRaw = newValue.rawValue }
    }

    var clarificationSuggestions: [MealClarification] {
        get {
            guard let clarificationSuggestionsData else { return [] }
            return (try? JSONDecoder().decode([MealClarification].self, from: clarificationSuggestionsData)) ?? []
        }
        set { clarificationSuggestionsData = try? JSONEncoder().encode(newValue) }
    }
}

enum LoggingMethod: String, Codable, CaseIterable {
    case ai, repeatMeal = "repeat"
}

enum MealAnalysisStatus: String, Codable {
    case pending, resolved, failed
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
    var sourceTierRaw: String?
    /// Per-food nutrition, added in Dayplate 1.4. Optional so meals logged before
    /// the service reported it keep showing no breakdown rather than a false zero.
    var calories: Double?
    var carbohydrates: Double?
    var protein: Double?
    var fat: Double?
    var meal: MealLog?

    init(
        canonicalName: String,
        portion: String,
        quantity: Double = 1,
        catalogFoodID: String? = nil,
        sourceRecordIDs: [String] = [],
        brandName: String? = nil,
        sourceName: String? = nil,
        sourceTier: NutritionSourceTier? = nil,
        calories: Double? = nil,
        carbohydrates: Double? = nil,
        protein: Double? = nil,
        fat: Double? = nil
    ) {
        self.canonicalName = canonicalName
        self.portion = portion
        self.quantity = quantity
        self.catalogFoodID = catalogFoodID
        self.sourceRecordIDs = sourceRecordIDs
        self.brandName = brandName
        self.sourceName = sourceName
        self.sourceTierRaw = sourceTier?.rawValue
        self.calories = calories
        self.carbohydrates = carbohydrates
        self.protein = protein
        self.fat = fat
    }

    /// True only when the service reported a complete per-food breakdown.
    var hasNutrition: Bool { calories != nil && carbohydrates != nil && protein != nil && fat != nil }


    var sourceTier: NutritionSourceTier? {
        get { sourceTierRaw.flatMap(NutritionSourceTier.init(rawValue:)) }
        set { sourceTierRaw = newValue?.rawValue }
    }
}

enum NutritionSourceTier: String, Codable {
    case label
    case usda
    case openFoodFacts = "open_food_facts"
    case brand
    case web

    var shortLabel: String {
        switch self {
        case .label: "Nutrition label photo"
        case .usda: "USDA"
        case .openFoodFacts: "Open Food Facts"
        case .brand: "Brand source"
        case .web: "Web source"
        }
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
    var identifiedFoods: [String] = []
    var clarificationAnswersData: Data?
    var clarificationRound: Int = 0
    var targetMealID: UUID?
    var attemptCount: Int = 0
    var lastError: String?

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        descriptionText: String,
        mealPhotoPath: String? = nil,
        nutritionLabelPhotoPath: String? = nil,
        photoPaths: [String] = [],
        identifiedFoods: [String] = [],
        clarificationAnswersData: Data? = nil,
        clarificationRound: Int = 0,
        targetMealID: UUID? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.descriptionText = descriptionText
        self.mealPhotoPath = mealPhotoPath
        self.nutritionLabelPhotoPath = nutritionLabelPhotoPath
        self.photoPaths = photoPaths
        self.identifiedFoods = identifiedFoods
        self.clarificationAnswersData = clarificationAnswersData
        self.clarificationRound = clarificationRound
        self.targetMealID = targetMealID
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

struct MealDraftFood: Equatable, Codable {
    var name: String
    var portion: String
    var sourceName: String?
    var sourceTier: NutritionSourceTier?
    /// Optional so drafts cached by earlier versions still decode.
    var calories: Double?
    var carbohydrates: Double?
    var protein: Double?
    var fat: Double?
}

struct MealDraft: Equatable, Codable {
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
    var foods: [MealDraftFood]
    var clarifications: [MealClarification] = []
    var loggingMethod: LoggingMethod = .ai
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
        lhs.foods == rhs.foods &&
        lhs.clarifications == rhs.clarifications
    }
}
