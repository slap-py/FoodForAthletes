# Athlete-first food logger — detailed AI and nutrition plan

## Core rule

AI identifies the meal; the curated catalog calculates nutrition.

The AI must never invent calories, carbs, protein, or micronutrients. It determines a title, foods/dishes, preparation, and approximate household portions from the user’s detailed sentence plus photo. The backend then maps those selections to authoritative catalog data and calculates totals.

## Meal-analysis flow

1. The iPhone submits the required meal description, photo, capture time, timezone, and an idempotency key to `POST /v1/meal-analysis`.
2. A Cloudflare Worker validates App Attest, rate-limits a privacy-preserving device identifier, and sends the text plus transient image input to the OpenAI Responses API.
3. Use **GPT-5.6 Terra** with low reasoning as the production baseline; pin an approved dated snapshot after evaluating it against the app’s meal test set.
4. The model calls a backend-only `search_catalog` tool for each detected food or common dish. Tool results expose canonical names, aliases, preparation variants, and household portion profiles—but no nutrient values.
5. The model returns strict structured output: a concise AI-generated title, canonical catalog IDs, portions, assumptions, and a text/photo reconciliation note. Written text is weighted heavily, but the model may use the photo to correct clear conflicts or estimate visible size.
6. The Worker calculates nutrients deterministically from catalog records and returns the review draft. The app shows the title and rounded totals first; food components and nutrient detail are expandable.
7. If the draft is wrong, the user revises the sentence and reruns analysis. There is no manual food-search, barcode, manual nutrient-entry, or “skip AI” flow.

## AI contract

- Prioritize the user’s words; use the photo for corroboration, visible components, and portion sizing.
- Resolve every food through catalog IDs; choose common dishes when appropriate; never generate nutrition values; never ask follow-up questions.
- Normalize portions such as `2 cups`, `handful`, `scoop`, `slice`, or `medium bowl` to catalog profiles.
- Return `title`, `items[]`, `assumptionNotes[]`, and `analysisVersion`; the server appends calculated nutrients and `catalogVersion`.
- Always return the best draft. Show a brief assumption only when useful; do not display confidence scores.
- Generate concise titles such as `Pasta & Breadsticks`; retain the original sentence below it.

## Curated nutrition catalog

- Import USDA FoodData Central Foundation Foods and FNDDS releases into a versioned catalog, not a live raw search.
- Build a broad U.S.-focused catalog with both U.S. and metric portions, including several thousand canonical generic foods and common dishes.
- Store canonical foods, preparation variants, portion profiles, dish compositions, aliases, and source/version data.
- Merge duplicate source rows into one user-facing food. Preparation differences remain internal variants.
- Use curated aliases and full-text ranking in D1 for `search_catalog`; return at most eight candidates per model tool call.

## Nutrients, privacy, and testing

- Store a nutrient snapshot at save time: calories, carbs, protein, fat, fiber, calcium, iron, magnesium, potassium, sodium, and vitamin D.
- Display rounded calories and whole nutrient units. Keep macros/fiber prominent; put micronutrients in expandable meal and daily details.
- Do not retain meal photos or backend meal history. Keep final logs in private iCloud.
- Maintain a labeled sentence/photo regression set for catalog selection, portion sizing, title quality, text/photo conflicts, and deterministic nutrition calculations.
