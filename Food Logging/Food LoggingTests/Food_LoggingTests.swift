//
//  Food_LoggingTests.swift
//  Food LoggingTests
//
//  Created by Kai Bergman on 8/16/26.
//

import Foundation
import Testing
@testable import Food_Logging

struct Food_LoggingTests {

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
        #expect(meal.analysisStatus == .resolved)
        #expect(meal.calories == 600)
    }

    @Test func pendingMealsKeepLifecycleSeparateFromLoggingMethod() {
        let meal = MealLog(
            title: "Breakfast",
            descriptionText: "eggs and toast",
            calories: 0,
            carbohydrates: 0,
            protein: 0,
            fat: 0,
            fiber: 0,
            assumptions: "",
            loggingMethod: .ai,
            analysisStatus: .pending
        )

        #expect(meal.analysisStatus == .pending)
        #expect(meal.loggingMethod == .ai)
    }

    @Test func waterUsesConfiguredSnapshotAmount() {
        let water = WaterLog(milliliters: 240)
        #expect(water.milliliters == 240)
    }

    @Test func waterDisplayUsesStableRoundedUnitLabels() {
        #expect(WaterDisplay.amount(240, unitSystem: "us") == "8 oz")
        #expect(WaterDisplay.amount(240, unitSystem: "metric") == "240 mL")
    }

    @Test func mealEmojiPrefersSpecificFoodOverGenericPlate() {
        #expect(MealEmoji.symbol(for: "Bacon and eggs") == "🥓")
        #expect(MealEmoji.symbol(for: "Frosted chocolate Pop-Tarts") == "🍫")
        #expect(MealEmoji.symbol(for: "Something unknown") == "🍽️")
        let meal = MealLog(title: "Breakfast", descriptionText: "I ate bacon", calories: 0, carbohydrates: 0, protein: 0, fat: 0, fiber: 0, assumptions: "")
        #expect(MealEmoji.symbol(for: meal) == "🥓")
    }

}
