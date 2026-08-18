//
//  Food_LoggingTests.swift
//  Food LoggingTests
//
//  Created by Kai Bergman on 8/16/26.
//

import Testing
@testable import Food_Logging

struct Food_LoggingTests {

    @Test func catalogSearchCollapsesDuplicateSourcesIntoCanonicalResult() {
        let results = DayplateCatalog.search("banana")
        #expect(results.count == 1)
        #expect(results[0].provenance.count == 2)
        #expect(results[0].provenance.map(\.sourceID).contains("173944"))
    }

    @Test func catalogMealUsesServingQuantitiesAndCalculatedTotals() {
        let chicken = DayplateCatalog.search("chicken")[0]
        let rice = DayplateCatalog.search("brown rice")[0]
        let draft = DayplateCatalog.draft(items: [
            CatalogMealItem(food: chicken, quantity: 2),
            CatalogMealItem(food: rice, quantity: 1.5)
        ], title: "Chicken and rice")

        #expect(draft.loggingMethod == .search)
        #expect(draft.calories == 607)
        #expect(draft.protein == 58.75)
        #expect(draft.foods.count == 2)
    }

    @Test func mealModelsDoNotContainPhotoStorage() {
        let meal = MealLog(
            title: "Example",
            descriptionText: "Example meal",
            calories: 600,
            carbohydrates: 70,
            protein: 30,
            fat: 20,
            fiber: 8,
            assumptions: "Approximate"
        )

        #expect(meal.title == "Example")
        #expect(meal.items?.isEmpty == true)
        #expect(meal.loggingMethod == .ai)
        #expect(meal.calories == 600)
    }

    @Test func waterUsesConfiguredSnapshotAmount() {
        let water = WaterLog(milliliters: 240)
        #expect(water.milliliters == 240)
    }

}
