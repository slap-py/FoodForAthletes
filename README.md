# Food For Athletes

Food For Athletes is an iPhone-only SwiftUI meal and water logger designed around athletes' real eating rhythms. Users can describe a meal, add a meal photo, add a nutrition-label photo, or combine those inputs (up to two photos total). The app identifies approximate foods, portions, calories, and macros, then presents a compact editable review before saving. At least one input is required.

The app focuses on meal timing, meal gaps, hydration, and neutral carbohydrate/protein distribution. It avoids calorie budgets, weight-loss goals, grades, deficits, and diet advice. Meals can be logged again from time-aware memory, and water can be added with one tap.

## v1

- SwiftUI for iOS 17+
- SwiftData with private iCloud/CloudKit sync
- Approximate food and macro interpretation from text, a meal photo, and/or a nutrition-label photo
- Direct OpenAI vision analysis from the iPhone, receiving the description, meal photo, and label photo together
- Direct USDA FoodData Central Foundation Foods/FNDDS lookup and deterministic nutrient calculation for non-label foods
- Offline retry, editable review cards, repeat meals, and configurable water amounts

Training plans, exercise integration, coaching, nutrition targets, medication, and weight-loss features are intentionally deferred.

## Repository contents

- `Food Logging/` — the SwiftUI iPhone app source and Xcode project
- `plans/` — product and implementation plans
- `README.md` — project overview and current scope

Open `Food Logging/Food Logging.xcodeproj` in Xcode to build and run the app. The project targets iOS 17 or later.

## Direct meal analysis

The app has no meal-analysis server. In Settings, add a personal OpenAI API key and USDA FoodData Central API key. They are saved in the current iPhone's Keychain with device-only accessibility and are never included in meal history or iCloud sync.

When the user analyzes a meal, the app sends the description plus both optional images in one OpenAI Responses API request. The model visually reads the Nutrition Facts label—there is no client-side OCR—and calls a local USDA catalog-search tool for food IDs. The iPhone then fetches USDA nutrient records and calculates the final totals. The two images are transient request data and are never saved with a meal.
