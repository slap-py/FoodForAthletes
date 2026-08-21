# Dayplate

Dayplate is an iPhone-only SwiftUI meal and water logger built around quick, flexible natural-language entry, photos, voice input, and time-aware meal repeats.

The app focuses on meal timing, meal gaps, hydration, and neutral carbohydrate/protein distribution. It avoids calorie budgets, weight-loss goals, grades, deficits, and diet advice. Meals can be logged again from time-aware memory, and water can be added with one tap.

## v1.3

- SwiftUI for iOS 17+
- SwiftData with private iCloud/CloudKit sync
- Ingredient-level meal logs with source details retained for each food
- USDA FoodData Central for generic and branded foods, Open Food Facts for branded fallback, then manufacturer-site fallback
- Food and macro interpretation from optional text and up to three undifferentiated photos
- Service-backed OpenAI analysis and Whisper transcription
- Offline AI retry, locally available repeat meals, App Shortcut routing, and configurable water amounts

Training plans, exercise integration, coaching, nutrition targets, medication, and weight-loss features are intentionally deferred.

## Repository contents

- `Food Logging/` — the SwiftUI iPhone app source and Xcode project
- `catalog-service/` — ingredient sourcing, meal analysis, transcription, and verification service
- `plans/` — product and implementation plans
- `README.md` — project overview and current scope

Open `Food Logging/Food Logging.xcodeproj` in Xcode to build and run the app. The project targets iOS 17 or later.

## Meal analysis

Each meal is separated into meal-level ingredients, rather than recipe subcomponents. Generic items use the full USDA FoodData Central search corpus. Branded items use USDA Branded Food Products, then Open Food Facts, then a manufacturer-site lookup. A separate GPT sanity check runs before the result is returned. The service owns the USDA and OpenAI credentials; no provider keys are stored in the iPhone app.

When the user analyzes a meal, the app sends the optional description plus up to three photos to the Dayplate service. Images and recorded audio are transient request data and are never saved with a meal; when a meal is queued offline, photos are held only in protected device storage until analysis succeeds, then deleted.
