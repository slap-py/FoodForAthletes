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
    var assumptions: String
    var foods: [(name: String, portion: String)]

    static func == (lhs: MealDraft, rhs: MealDraft) -> Bool {
        lhs.title == rhs.title && lhs.calories == rhs.calories
    }
}

enum PlaceholderMealAnalysis {
    /// UI-only fixture. No image or meal text leaves the device.
    static func draft(for description: String) -> MealDraft {
        let cleaned = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ").prefix(6).joined(separator: " ")
        let title = words.isEmpty ? "Meal preview" : words.capitalized

        return MealDraft(
            title: title,
            calories: 640,
            carbohydrates: 78,
            protein: 34,
            fat: 22,
            fiber: 9,
            assumptions: "Illustrative values only. The food analysis service is not connected in this version.",
            foods: [
                ("Example carbohydrate", "about 1½ cups"),
                ("Example protein", "about one palm-sized portion"),
                ("Example vegetables", "about 1 cup")
            ]
        )
    }
}
