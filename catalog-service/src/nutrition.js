const USDA_API_URL = "https://api.nal.usda.gov/fdc/v1";
const OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/cgi/search.pl";
const ingredientCache = new Map();

export class NutritionSourceError extends Error {}

/**
 * Resolves a meal-level ingredient, never recipe subcomponents. Generic foods
 * search the full FoodData Central corpus. Branded foods use FDC Branded first,
 * then Open Food Facts, then the caller-provided manufacturer lookup.
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
  const candidate = dataType ? foods[0] : foods.find(food => String(food?.dataType).toLowerCase() !== "branded") ?? foods[0];
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
  const product = asArray((await response.json())?.products).find(item => positiveNumber(item?.nutriments?.["energy-kcal_100g"] ?? item?.nutriments?.energy_kcal_100g, 0) > 0);
  if (!product) return null;
  const nutrients = product.nutriments ?? {};
  return {
    name: product.product_name ?? query,
    portion: portionLabel(grams),
    sourceName: "Open Food Facts",
    sourceID: String(product.code ?? product.id ?? query),
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
  if (!result?.nutrientsPer100g || positiveNumber(result.nutrientsPer100g.calories, 0) <= 0) return null;
  return {
    name: result.name || [ingredient.brand, ingredient.name].filter(Boolean).join(" "),
    portion: portionLabel(ingredient.grams),
    sourceName: "Manufacturer website",
    sourceID: result.sourceURL || "manufacturer-site",
    nutrients: normalizeNutrients(result.nutrientsPer100g, ingredient.grams / 100)
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
