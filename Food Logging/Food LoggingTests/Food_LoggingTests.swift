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

    @Test func historySummariesCombineDayLogsAndKeepWaterOnlyDaysDistinct() {
        let calendar = Calendar(identifier: .gregorian)
        let firstMeal = MealLog(
            timestamp: date(2026, 8, 12, 8, 30, calendar: calendar),
            title: "Breakfast",
            descriptionText: "",
            calories: 500,
            carbohydrates: 60,
            protein: 25,
            fat: 15,
            fiber: 8,
            assumptions: ""
        )
        let secondMeal = MealLog(
            timestamp: date(2026, 8, 12, 13, 0, calendar: calendar),
            title: "Lunch",
            descriptionText: "",
            calories: 700,
            carbohydrates: 80,
            protein: 35,
            fat: 20,
            fiber: 10,
            assumptions: ""
        )
        let sameDayWater = WaterLog(timestamp: date(2026, 8, 12, 9, 0, calendar: calendar), milliliters: 500)
        let waterOnly = WaterLog(timestamp: date(2026, 8, 13, 9, 0, calendar: calendar), milliliters: 240)

        let summaries = HistoryDaySummary.grouped(meals: [secondMeal, firstMeal], water: [sameDayWater, waterOnly], calendar: calendar)
        let mealDay = summaries[calendar.startOfDay(for: firstMeal.timestamp)]!
        let waterDay = summaries[calendar.startOfDay(for: waterOnly.timestamp)]!

        #expect(mealDay.mealCount == 2)
        #expect(mealDay.calories == 1200)
        #expect(mealDay.carbohydrates == 140)
        #expect(mealDay.protein == 60)
        #expect(mealDay.waterMilliliters == 500)
        #expect(mealDay.firstMeal == firstMeal.timestamp)
        #expect(mealDay.hasMeals)
        #expect(waterDay.hasEntries)
        #expect(!waterDay.hasMeals)
        #expect(waterDay.waterMilliliters == 240)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

}
