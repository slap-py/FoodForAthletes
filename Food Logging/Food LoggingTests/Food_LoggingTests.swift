//
//  Food_LoggingTests.swift
//  Food LoggingTests
//
//  Created by Kai Bergman on 8/16/26.
//

import Testing
@testable import Food_Logging

struct Food_LoggingTests {

    @Test func placeholderAnalysisIsClearlyApproximateAndDeterministic() {
        let draft = PlaceholderMealAnalysis.draft(for: "rice bowl with chicken and avocado")

        #expect(draft.title == "Rice Bowl With Chicken And Avocado")
        #expect(draft.carbohydrates == 78)
        #expect(draft.protein == 34)
        #expect(draft.assumptions.contains("not connected"))
        #expect(draft.foods.count == 3)
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
    }

    @Test func waterUsesConfiguredSnapshotAmount() {
        let water = WaterLog(milliliters: 240)
        #expect(water.milliliters == 240)
    }

}
