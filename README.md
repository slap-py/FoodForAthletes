# Dayplate

Dayplate is an iPhone-only SwiftUI meal and water logger built around quick, flexible entry. Its main picker offers catalog search, an optional text/photo AI estimate, and time-aware meal repeats. Search builds a timestamped multi-item meal from canonical USDA-derived generic and branded foods without calling OpenAI.

The app focuses on meal timing, meal gaps, hydration, and neutral carbohydrate/protein distribution. It avoids calorie budgets, weight-loss goals, grades, deficits, and diet advice. Meals can be logged again from time-aware memory, and water can be added with one tap.

## v1.3

- SwiftUI for iOS 17+
- SwiftData with private iCloud/CloudKit sync
- Versioned Dayplate catalog records with normalized names, brands, servings, nutrients, and USDA provenance
- FatSecret-first food search with USDA FoodData Central supplemental results (no deduplication yet)
- Optional food and macro interpretation from text, a meal photo, and/or a nutrition-label photo
- Service-backed OpenAI vision analysis, receiving the description, meal photo, label photo, and FatSecret NLP output together
- Offline AI retry, locally available repeat meals, App Shortcut routing, and configurable water amounts

Training plans, exercise integration, coaching, nutrition targets, medication, and weight-loss features are intentionally deferred.

## Repository contents

- `Food Logging/` — the SwiftUI iPhone app source and Xcode project
- `catalog-service/` — versioned canonical catalog pipeline plus search/detail HTTP reference service
- `plans/` — product and implementation plans
- `README.md` — project overview and current scope

Open `Food Logging/Food Logging.xcodeproj` in Xcode to build and run the app. The project targets iOS 17 or later.

## Direct meal analysis

Catalog search and AI estimate are independent. Catalog search calls the Dayplate service, which queries FatSecret first and appends USDA FoodData Central results without deduplication. The service owns the FatSecret, OpenAI, and USDA credentials; no provider keys are stored in the iPhone app.

When the user analyzes a meal, the app sends the description plus both optional images to the Dayplate service. The service calls FatSecret NLP with the text, then supplies that output, the original text, and both optional images in one OpenAI Responses API request. Images are transient request data and are never saved with a meal; when a meal is queued offline, they are held only in protected device storage until analysis succeeds, then deleted.
