//
//  Food_LoggingTests.swift
//  Food LoggingTests
//
//  Created by Kai Bergman on 8/16/26.
//

import Testing
@testable import Food_Logging

struct Food_LoggingTests {

    @Test func localAnalysisUsesMatchedFoodsAndCalculatedMacros() async throws {
        let draft = try await MealAnalysisService.shared.analyze(
            MealAnalysisInput(
                description: "rice bowl with chicken and avocado",
                mealPhotoData: nil,
                nutritionLabelPhotoData: nil
            )
        )

        #expect(draft.title == "Rice Bowl With Chicken And Avocado")
        #expect(draft.calories == 453)
        #expect(draft.carbohydrates == 51.4)
        #expect(draft.protein == 31.8)
        #expect(draft.foods.map(\.name) == ["Chicken breast", "Rice", "Avocado"])
        #expect(draft.assumptions.contains("USDA-derived"))
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
