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
