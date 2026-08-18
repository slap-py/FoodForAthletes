# Dayplate

Dayplate is an iPhone-only SwiftUI meal and water logger built around quick, flexible entry. Its main picker offers catalog search, an optional text/photo AI estimate, and time-aware meal repeats. Search builds a timestamped multi-item meal from canonical USDA-derived generic and branded foods without calling OpenAI.

The app focuses on meal timing, meal gaps, hydration, and neutral carbohydrate/protein distribution. It avoids calorie budgets, weight-loss goals, grades, deficits, and diet advice. Meals can be logged again from time-aware memory, and water can be added with one tap.

## v1.3

- SwiftUI for iOS 17+
- SwiftData with private iCloud/CloudKit sync
- Versioned Dayplate catalog records with normalized names, brands, servings, nutrients, and USDA provenance
- Search-led multi-item meal building with deterministic nutrient calculation and no OpenAI dependency
- Optional food and macro interpretation from text, a meal photo, and/or a nutrition-label photo
- Direct OpenAI vision analysis from the iPhone, receiving the description, meal photo, and label photo together
- Direct USDA FoodData Central Foundation Foods/FNDDS lookup and deterministic nutrient calculation for non-label foods
- Offline AI retry, locally available repeat meals, App Shortcut routing, and configurable water amounts

Training plans, exercise integration, coaching, nutrition targets, medication, and weight-loss features are intentionally deferred.

## Repository contents

- `Food Logging/` — the SwiftUI iPhone app source and Xcode project
- `catalog-service/` — versioned canonical catalog pipeline plus search/detail HTTP reference service
- `plans/` — product and implementation plans
- `README.md` — project overview and current scope

Open `Food Logging/Food Logging.xcodeproj` in Xcode to build and run the app. The project targets iOS 17 or later.

## Direct meal analysis

Catalog search and AI estimate are independent. Catalog search never calls OpenAI. In Settings, users who want AI estimates can add personal OpenAI and USDA FoodData Central API keys; they are saved in the current iPhone's Keychain with device-only accessibility and are never included in meal history or iCloud sync.

When the user analyzes a meal, the app sends the description plus both optional images in one OpenAI Responses API request. The model visually reads the Nutrition Facts label—there is no client-side OCR—and calls a local USDA catalog-search tool for food IDs. The iPhone then fetches USDA nutrient records and calculates the final totals. Images are transient request data and are never saved with a meal; when a meal is queued offline, they are held only in protected device storage until analysis succeeds, then deleted.
