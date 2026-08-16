# Athlete-first food logger — v1 plan

## Summary

Build an iPhone-only SwiftUI app for fast meal and water logging. Every new meal is submitted as a short sentence plus a photo, interpreted into approximate foods, portions, and macros, then saved from a compact editable review card. The app emphasizes meal timing, eating rhythm, and carbohydrate/protein distribution—never calorie budgets, deficits, weight goals, grades, or diet advice.

## Implementation

- **iOS app:** SwiftUI, iOS 17+, SwiftData with private iCloud/CloudKit sync; no separate account.
- **Capture flow:** Require sentence + photo for a new meal. Delete temporary photos after successful analysis and save.
- **Meal review:** Show canonical foods, approachable portions, macro estimates, and useful assumptions; save in one tap or edit.
- **Water:** Add a one-tap `8 fl oz / 240 mL` action with configurable quick amounts.
- **Today timeline:** Center meal timing, meal gaps, meal-level carb/protein content, and neutral macro distribution. Calories remain secondary, never a target.
- **Memory:** Surface time-aware repeated-meal suggestions. A tap logs the prior confirmed meal at the current time without a new photo.
- **Deferred:** Training plans, exercise integration, medication, coaching, nutrition targets, and weight-loss features.

## Data and services

- Store `MealLog`, `MealItem`, `WaterLog`, preferences, and a locally cached catalog in SwiftData/iCloud. Retain nutrient snapshots, not meal photos.
- Seed an app-owned canonical catalog from USDA FoodData Central, with aliases, common portions, source metadata, and a single user-facing entry per generic food.
- Use a small serverless API to protect credentials and call the OpenAI Responses API for text-and-photo interpretation. The catalog service performs nutrient calculation from recognized catalog IDs.
- Send photos only as transient analysis payloads; do not retain meal history on the backend.

## Testing and acceptance

- Test phrase and image fixtures, canonical matching, portions, macro calculation, low-confidence handling, edits, repeats, water, offline retry, timezone boundaries, and iCloud sync.
- Ensure no UI or copy includes calorie budgets, deficits, “over/under” language, or weight-loss messaging.
- Target under 15 seconds for a new meal; one tap for water and repeat meals.

## Assumptions

- Estimates are deliberately approximate and use plain-language assumptions.
- The first catalog favors common generic foods and mixed dishes; branded and restaurant depth comes later.
- Future training-aware fueling will build on meal timestamps and nutrient snapshots, not calorie compensation.
