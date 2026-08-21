import { curatedMenuProduct } from "./menuProducts.js";

const USDA_API_URL = "https://api.nal.usda.gov/fdc/v1";
const OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/cgi/search.pl";
const ingredientCache = new Map();

export class NutritionSourceError extends Error {}

/**
 * Resolves a meal-level food, never recipe subcomponents. Branded restaurant
 * and packaged menu items are kept intact as one product. They use an exact
 * FDC Branded match first, then Open Food Facts, then the caller-provided
 * official-manufacturer lookup.
 */
export async function sourceIngredient(ingredient, credentials, manufacturerLookup, request = fetch) {
  const cacheKey = JSON.stringify([ingredient.kind, ingredient.brand ?? "", ingredient.name, Math.round(positiveNumber(ingredient.grams, 100))]);
  if (ingredientCache.has(cacheKey)) return ingredientCache.get(cacheKey);
  const sourced = await sourceIngredientUncached(ingredient, credentials, manufacturerLookup, request);
  ingredientCache.set(cacheKey, sourced);
  return sourced;
}

async function sourceIngredientUncached(ingredient, credentials, manufacturerLookup, request) {
  const query = [ingredient.brand, ingredient.name].filter(Boolean).join(" ");
  const grams = positiveNumber(ingredient.grams, 100);

  if (ingredient.kind === "branded") {
    const curated = curatedMenuProduct(ingredient);
    if (curated) return curatedProductNutrition(curated, grams);
    const branded = await usdaIngredient(query, grams, credentials.foodDataCentralKey, request, "Branded");
    if (branded) return branded;
    const off = await openFoodFactsIngredient(query, grams, request);
    if (off) return off;
    const manufacturer = await manufacturerLookup({ ...ingredient, grams });
    if (manufacturer) return manufacturer;
    throw new NutritionSourceError(`No nutrition source found for branded food: ${query}`);
  }

  const generic = await usdaIngredient(query, grams, credentials.foodDataCentralKey, request);
  if (generic) return generic;
  throw new NutritionSourceError(`No USDA nutrition source found for: ${query}`);
}

async function usdaIngredient(query, grams, apiKey, request, dataType) {
  if (!apiKey) throw new NutritionSourceError("USDA_FOODDATA_API_KEY is not configured.");
  const params = new URLSearchParams({ query, pageSize: "8", api_key: apiKey });
  if (dataType) params.set("dataType", dataType);
  const searchResponse = await request(`${USDA_API_URL}/foods/search?${params}`);
  if (!searchResponse.ok) throw new NutritionSourceError("USDA search failed.");
  const search = await searchResponse.json();
  const foods = asArray(search?.foods);
  const candidate = bestUsdaCandidate(foods, query, dataType);
  if (!candidate?.fdcId) return null;

  const detailResponse = await request(`${USDA_API_URL}/food/${candidate.fdcId}?api_key=${encodeURIComponent(apiKey)}`);
  if (!detailResponse.ok) throw new NutritionSourceError("USDA food detail lookup failed.");
  const food = await detailResponse.json();
  const perPortion = usdaNutrients(food, grams);
  if (perPortion.calories <= 0) return null;
  return {
    name: food.description ?? candidate.description ?? query,
    portion: portionLabel(grams, ingredientPortionHint(food)),
    sourceName: dataType ? "USDA FoodData Central — Branded" : "USDA FoodData Central",
    sourceID: String(candidate.fdcId),
    nutrients: perPortion
  };
}

function usdaNutrients(food, grams) {
  const label = food?.labelNutrients;
  const servingSize = positiveNumber(food?.servingSize, 0);
  if (label && servingSize > 0) {
    const scale = grams / servingSize;
    return normalizeNutrients({
      calories: label.calories?.value,
      carbohydrates: label.carbohydrates?.value,
      protein: label.protein?.value,
      fat: label.fat?.value,
      fiber: label.fiber?.value,
      calcium: label.calcium?.value,
      iron: label.iron?.value,
      potassium: label.potassium?.value,
      sodium: label.sodium?.value,
      vitaminD: label.vitaminD?.value
    }, scale);
  }
  const values = Object.fromEntries(asArray(food?.foodNutrients).map(item => [String(item?.nutrient?.name ?? item?.nutrientName ?? "").toLowerCase(), item.amount]));
  return normalizeNutrients({
    calories: values.energy,
    carbohydrates: values["carbohydrate, by difference"],
    protein: values.protein,
    fat: values["total lipid (fat)"],
    fiber: values["fiber, total dietary"],
    calcium: values["calcium, ca"],
    iron: values["iron, fe"],
    magnesium: values["magnesium, mg"],
    potassium: values["potassium, k"],
    sodium: values["sodium, na"],
    vitaminD: values["vitamin d (d2 + d3)"]
  }, grams / 100);
}

async function openFoodFactsIngredient(query, grams, request) {
  const params = new URLSearchParams({ search_terms: query, search_simple: "1", action: "process", json: "1", page_size: "8" });
  const response = await request(`${OPEN_FOOD_FACTS_URL}?${params}`, { headers: { "user-agent": "Dayplate/1.0 nutrition lookup" } });
  if (!response.ok) return null;
  const queryTokens = new Set(normalize(query).split(" ").filter(Boolean));
  const product = asArray((await response.json())?.products)
    .filter(item => positiveNumber(item?.nutriments?.["energy-kcal_100g"] ?? item?.nutriments?.energy_kcal_100g, 0) > 0)
    .map(item => {
      const text = normalize([item.product_name, item.brands].filter(Boolean).join(" "));
      const matches = [...queryTokens].filter(token => text.split(" ").includes(token)).length;
      return { item, score: queryTokens.size ? matches / queryTokens.size : 0 };
    })
    .sort((left, right) => right.score - left.score)[0];
  if (!product || product.score < 0.7) return null;
  const nutrients = product.item.nutriments ?? {};
  return {
    name: product.item.product_name ?? query,
    portion: portionLabel(grams),
    sourceName: "Open Food Facts",
    sourceID: String(product.item.code ?? product.item.id ?? query),
    nutrients: normalizeNutrients({
      calories: nutrients["energy-kcal_100g"] ?? nutrients.energy_kcal_100g,
      carbohydrates: nutrients.carbohydrates_100g,
      protein: nutrients.proteins_100g,
      fat: nutrients.fat_100g,
      fiber: nutrients.fiber_100g,
      calcium: nutrients.calcium_100g && nutrients.calcium_100g * 1000,
      iron: nutrients.iron_100g && nutrients.iron_100g * 1000,
      potassium: nutrients.potassium_100g && nutrients.potassium_100g * 1000,
      sodium: nutrients.sodium_100g && nutrients.sodium_100g * 1000
    }, grams / 100)
  };
}

export function manufacturerNutrition(ingredient, result) {
  if (!result?.nutrientsPerServing || positiveNumber(result.nutrientsPerServing.calories, 0) <= 0) return null;
  const servingGrams = positiveNumber(result.servingGrams, 0);
  const scale = servingGrams > 0 ? ingredient.grams / servingGrams : 1;
  return {
    name: result.name || [ingredient.brand, ingredient.name].filter(Boolean).join(" "),
    portion: result.servingLabel || portionLabel(ingredient.grams),
    sourceName: result.sourceName || "Manufacturer website",
    sourceID: result.sourceURL || "manufacturer-site",
    nutrients: normalizeNutrients(result.nutrientsPerServing, scale)
  };
}

function curatedProductNutrition(product, grams) {
  const servings = Math.max(1, Math.round(grams / product.servingGrams));
  return {
    name: product.name,
    portion: servings === 1 ? product.servingLabel : String(servings) + " × " + product.servingLabel,
    sourceName: product.sourceName,
    sourceID: product.sourceURL,
    nutrients: normalizeNutrients(product.nutrientsPerServing, servings)
  };
}

export function totals(ingredients) { return ingredients.reduce((sum, item) => add(sum, item.nutrients), zeroNutrients()); }
export function zeroNutrients() { return { calories: 0, carbohydrates: 0, protein: 0, fat: 0, fiber: 0, calcium: 0, iron: 0, magnesium: 0, potassium: 0, sodium: 0, vitaminD: 0 }; }

function normalizeNutrients(values, scale) {
  return Object.fromEntries(Object.keys(zeroNutrients()).map(key => [key, positiveNumber(values[key], 0) * scale]));
}
function add(a, b) { return Object.fromEntries(Object.keys(a).map(key => [key, a[key] + b[key]])); }
function asArray(value) { return Array.isArray(value) ? value : value ? [value] : []; }
function positiveNumber(value, fallback) { const parsed = Number(value); return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback; }
function portionLabel(grams, hint) { return hint ? `${hint} (${Math.round(grams)} g)` : `${Math.round(grams)} g`; }
function ingredientPortionHint(food) { return food?.householdServingFullText || null; }
function normalize(value) {
  return String(value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function bestUsdaCandidate(foods, query, dataType) {
  const queryTokens = new Set(normalize(query).split(" ").filter(Boolean));
  const permittedFoods = dataType
    ? foods.filter(food => String(food?.dataType ?? "").toLowerCase() === dataType.toLowerCase())
    : foods.filter(food => String(food?.dataType ?? "").toLowerCase() !== "branded");
  const ranked = (permittedFoods.length ? permittedFoods : foods)
    .map(food => {
      const candidateText = normalize([food?.description, food?.brandOwner, food?.brandName].filter(Boolean).join(" "));
      const candidateTokens = new Set(candidateText.split(" ").filter(Boolean));
      const matches = [...queryTokens].filter(token => candidateTokens.has(token)).length;
      return { food, score: queryTokens.size ? matches / queryTokens.size : 0 };
    })
    .sort((left, right) => right.score - left.score);

  const candidate = ranked[0];
  if (!candidate) return null;
  // A loose branded match can have an unrelated nutrient panel. Let the
  // official-product fallback handle it instead of returning a plausible but
  // wrong item such as a different sandwich from the same chain.
  if (dataType && candidate.score < 0.7) return null;
  return candidate.food;
}
