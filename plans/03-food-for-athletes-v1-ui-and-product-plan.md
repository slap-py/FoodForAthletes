# Food for Athletes v1 — UI and product plan

## Summary

Build a calm, iPhone-first food journal that opens to a nutrition summary—not a calorie budget. Users log a new meal through one prominent centered action, review the AI estimate, and see their day as a time-first timeline. The UI prioritizes carbs and protein at the summary level, meal timing throughout, and calories as useful but secondary context.

## User interface

- **Navigation:** `Today`, `History`, and `Settings` sit in the bottom bar. A prominent centered `Log meal` action opens capture from every screen.
- **Today:** Header contains the current date, water total, and `+ 8 oz`. The home summary uses macro cards for carbs, protein, fat, and fiber; calories and micronutrients are expandable.
- **Meal rhythm:** Below the summary, show a horizontal daylight timeline with meal markers positioned by actual time and neutral gap labels. Do not assign breakfast/lunch/dinner categories.
- **Timeline:** Use spacious journal cards: exact time, AI meal title, carbs, and estimated calories. Tapping a card expands protein, fat, fiber, micronutrients, inferred foods/portions, and any concise assumptions. Saved meal photos are never shown or retained.
- **Log meal sheet:** Present a full-screen capture flow with a sentence field and required photo. Enable `Analyze meal` only when both exist. The top of this sheet may show a short “Usual around now” repeat-meal row; selecting one logs the saved meal immediately without a new photo.
- **Review:** Show AI-generated title, time, calories, carbs, protein, fat, and fiber. `Save meal` is primary; `Edit description` is the sole correction mechanism and reruns analysis. No food search, barcode scanner, manual nutrient input, or skip-AI path.
- **History:** Default to a selected-day timeline. Include a `Patterns` segment for neutral views of first-meal time, meal spacing, carb/protein distribution by time of day, and hydration history.
- **Settings:** Units (U.S. and metric), default water amount, iCloud status, photo/AI privacy explanation, data export/delete, and app appearance. Exclude weight, calorie goals, or nutrient targets.

## Design system and behavior

- Use a **calm field-journal** style: warm neutral surfaces, dark high-contrast typography, generous spacing, subtle nutrient accents, and no gamification.
- Avoid progress rings, red/green compliance states, streaks, “remaining” values, or any calorie-budget language.
- Show empty states factually: “No meals logged today” with the meal-log action, never a judgmental prompt.
- Support Dynamic Type, VoiceOver labels for nutrient values and timeline times, 44pt minimum touch targets, Reduce Motion, and color-independent macro identification.
- Keep meal cards time-first and unclassified so users can see their genuine eating pattern rather than fit their day into prescribed meal slots.

## Application and AI interface

- Use SwiftUI, iOS 17+, SwiftData, and private iCloud/CloudKit sync for final logs; retain nutrient snapshots but not photos.
- `POST /v1/meal-analysis` accepts meal text, transient image data, capture time, timezone, and an idempotency key; it returns `MealDraft` with title, canonical food/dish IDs, approachable portions, assumptions, calculated nutrient totals, analysis version, and catalog version.
- Use a Cloudflare Worker with a catalog-search tool and GPT-5.6 Terra at low reasoning. The model identifies foods and portions only; server-side catalog records calculate all nutrients. [OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model)
- Curate a broad U.S. catalog from USDA Foundation Foods and FNDDS, merging source duplicates into canonical user-facing foods and common dishes with U.S./metric portion profiles. [USDA FoodData Central](https://fdc.nal.usda.gov/api-guide/)
- Calculate calories, carbs, protein, fat, fiber, calcium, iron, magnesium, potassium, sodium, and vitamin D. Show rounded values; keep source precision internally.

## Test plan and defaults

- UI-test first-day empty state, full meal capture, in-progress analysis, retry after network failure, saved-meal expansion, text reanalysis, one-tap repeat meal, water add, History/Patterns navigation, and Settings.
- Verify meal cards show time, carbs, and calories without introducing targets; verify no visible copy refers to loss, deficits, budgets, “over,” or “under.”
- Validate accessibility at large Dynamic Type sizes, with VoiceOver, and without color perception.
- Default assumptions: U.S.-focused food coverage with dual units, repeat meals are the only no-photo logging exception, calories remain secondary to carbohydrates/protein, and meal photos are deleted after successful analysis.
