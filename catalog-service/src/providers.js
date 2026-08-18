const FATSECRET_TOKEN_URL = "https://oauth.fatsecret.com/connect/token";
const FATSECRET_API_URL = "https://platform.fatsecret.com/rest";
const USDA_API_URL = "https://api.nal.usda.gov/fdc/v1";

let cachedFatSecretToken;

/**
 * Credentials intentionally live only in the service environment. FatSecret's
 * OAuth documentation requires this proxy pattern for client credentials.
 */
export function credentialsFromEnvironment(environment = process.env) {
  return {
    fatSecretClientID: environment.FATSECRET_CLIENT_ID,
    fatSecretClientSecret: environment.FATSECRET_CLIENT_SECRET,
    foodDataCentralKey: environment.USDA_FOODDATA_API_KEY,
    openAIKey: environment.OPENAI_API_KEY
  };
}

export async function searchFoods(query, credentials, request = fetch) {
  const [fatSecret, usda] = await Promise.all([
    searchFatSecretFoods(query, credentials, request),
    searchUSDAFoods(query, credentials, request)
  ]);
  // Keep the two providers distinct. We intentionally do not deduplicate here.
  return [...fatSecret, ...usda];
}

export async function searchFatSecretFoods(query, credentials, request = fetch) {
  const token = await fatSecretToken(credentials, request);
  const parameters = new URLSearchParams({
    search_expression: query,
    max_results: "12",
    format: "json"
  });
  const response = await request(`${FATSECRET_API_URL}/foods/search/v1?${parameters}`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  const payload = await responseJSON(response, "fatsecret_food_search_failed");
  const results = asArray(payload?.foods?.food);
  // Search only provides one nominated serving. Fetch each food's detail so the
  // app can offer FatSecret's own standard portions (for example, "1 sandwich")
  // rather than inventing a 100 g serving.
  return Promise.all(results.map(async result => {
    try {
      return await fatSecretFoodDetails(result, token, request);
    } catch {
      // A detail lookup should not make an otherwise useful search result vanish.
      return fatSecretFood(result);
    }
  })).then(foods => foods.filter(Boolean));
}

async function fatSecretFoodDetails(searchResult, token, request) {
  if (!searchResult?.food_id) return null;
  const parameters = new URLSearchParams({ food_id: String(searchResult.food_id), format: "json" });
  const response = await request(`${FATSECRET_API_URL}/food/v5?${parameters}`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  const payload = await responseJSON(response, "fatsecret_food_get_failed");
  return fatSecretFood(payload?.food, searchResult);
}

export async function searchUSDAFoods(query, credentials, request = fetch) {
  requireCredential(credentials.foodDataCentralKey, "USDA_FOODDATA_API_KEY");
  const parameters = new URLSearchParams({ query, pageSize: "12", api_key: credentials.foodDataCentralKey });
  const response = await request(`${USDA_API_URL}/foods/search?${parameters}`);
  const payload = await responseJSON(response, "usda_food_search_failed");
  return asArray(payload?.foods).map(usdaFood).filter(Boolean);
}

export async function fatSecretToken(credentials, request = fetch) {
  if (cachedFatSecretToken && cachedFatSecretToken.expiresAt > Date.now() + 60_000) return cachedFatSecretToken.value;
  requireCredential(credentials.fatSecretClientID, "FATSECRET_CLIENT_ID");
  requireCredential(credentials.fatSecretClientSecret, "FATSECRET_CLIENT_SECRET");
  const basic = Buffer.from(`${credentials.fatSecretClientID}:${credentials.fatSecretClientSecret}`).toString("base64");
  const response = await request(FATSECRET_TOKEN_URL, {
    method: "POST",
    headers: { Authorization: `Basic ${basic}`, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "basic" }).toString()
  });
  const payload = await responseJSON(response, "fatsecret_token_failed");
  if (!payload?.access_token) throw new ProviderError("fatsecret_token_failed");
  cachedFatSecretToken = { value: payload.access_token, expiresAt: Date.now() + Number(payload.expires_in ?? 3600) * 1000 };
  return cachedFatSecretToken.value;
}

export function fatSecretFood(food, searchResult = null) {
  const description = String(food?.food_description ?? "");
  const nutrients = nutrientsFromDescription(description);
  if (!food?.food_id || !food?.food_name) return null;
  const selectedServing = String(searchResult?.food_description ?? description).match(/Per\s+(.+?)\s+-\s+Calories/i)?.[1];
  const servings = fatSecretServings(food?.servings?.serving);
  const fallbackServing = {
    id: "default",
    label: selectedServing ?? "1 serving",
    gramWeight: 0,
    nutrients
  };
  return {
    id: `fatsecret:${food.food_id}`,
    canonicalName: food.food_name,
    brandName: food.brand_name ?? null,
    searchAliases: [],
    servings: preferSelectedServing(servings, selectedServing, fallbackServing),
    provenance: [provenance("FatSecret", String(food.food_id), food.food_name)],
    catalogVersion: "fatsecret-usda-live-v1"
  };
}

function fatSecretServings(value) {
  return asArray(value).map((serving, index) => {
    const label = String(serving?.serving_description ?? "").trim();
    if (!label) return null;
    return {
      id: String(serving?.serving_id ?? `serving-${index}`),
      label,
      gramWeight: metricWeight(serving),
      nutrients: {
        calories: number(serving?.calories),
        carbohydrates: number(serving?.carbohydrate),
        protein: number(serving?.protein),
        fat: number(serving?.fat),
        fiber: number(serving?.fiber),
        calcium: number(serving?.calcium),
        iron: number(serving?.iron),
        magnesium: 0,
        potassium: number(serving?.potassium),
        sodium: number(serving?.sodium),
        vitaminD: number(serving?.vitamin_d)
      }
    };
  }).filter(Boolean);
}

function metricWeight(serving) {
  const amount = number(serving?.metric_serving_amount);
  const unit = String(serving?.metric_serving_unit ?? "").toLowerCase();
  if (unit === "g") return amount;
  if (unit === "oz") return amount * 28.3495;
  return 0;
}

function preferSelectedServing(servings, selectedLabel, fallback) {
  if (!servings.length) return [fallback];
  if (!selectedLabel || isWeightServing(selectedLabel)) return servings;
  const selected = normalizeServingLabel(selectedLabel);
  const index = servings.findIndex(serving => normalizeServingLabel(serving.label) === selected);
  if (index <= 0) return servings;
  return [servings[index], ...servings.slice(0, index), ...servings.slice(index + 1)];
}

function normalizeServingLabel(value) { return String(value).toLowerCase().replace(/\s+/g, " ").trim(); }
function isWeightServing(value) { return /^\s*[\d.]+\s*(g|gram|grams|ml|oz)\b/i.test(String(value)); }

export function usdaFood(food) {
  if (!food?.fdcId || !food?.description) return null;
  const values = Object.fromEntries(asArray(food.foodNutrients).map(nutrient => [String(nutrient.nutrientName ?? nutrient.name ?? "").toLowerCase(), number(nutrient.value ?? nutrient.amount)]));
  return {
    id: `usda:${food.fdcId}`,
    canonicalName: food.description,
    brandName: food.brandOwner ?? food.brandName ?? null,
    searchAliases: [],
    servings: [{ id: "100g", label: "100 g", gramWeight: 100, nutrients: {
      calories: values.energy ?? 0,
      carbohydrates: values["carbohydrate, by difference"] ?? 0,
      protein: values.protein ?? 0,
      fat: values["total lipid (fat)"] ?? 0,
      fiber: values["fiber, total dietary"] ?? 0,
      calcium: values["calcium, ca"] ?? 0,
      iron: values["iron, fe"] ?? 0,
      magnesium: values["magnesium, mg"] ?? 0,
      potassium: values["potassium, k"] ?? 0,
      sodium: values["sodium, na"] ?? 0,
      vitaminD: values["vitamin d (d2 + d3)"] ?? 0
    }}],
    provenance: [provenance("USDA FoodData Central", String(food.fdcId), food.description)],
    catalogVersion: "fatsecret-usda-live-v1"
  };
}

function nutrientsFromDescription(value) {
  const read = name => number(value.match(new RegExp(`${name}:\\s*([0-9.]+)g?`, "i"))?.[1]);
  return { calories: number(value.match(/Calories:\s*([0-9.]+)/i)?.[1]), carbohydrates: read("Carbs"), protein: read("Protein"), fat: read("Fat"), fiber: 0, calcium: 0, iron: 0, magnesium: 0, potassium: 0, sodium: 0, vitaminD: 0 };
}

function provenance(source, sourceID, sourceDescription) { return { source, sourceID, sourceDescription, importedAt: new Date().toISOString() }; }
function asArray(value) { return Array.isArray(value) ? value : value ? [value] : []; }
function number(value) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; }
function requireCredential(value, name) { if (!value) throw new ProviderError("service_not_configured", `${name} is not configured on the service.`); }
async function responseJSON(response, fallback) {
  let body;
  try { body = await response.json(); } catch { throw new ProviderError(fallback); }
  if (!response.ok) throw new ProviderError(fallback, body?.error?.message ?? body?.error?.error ?? undefined);
  return body;
}

export class ProviderError extends Error {
  constructor(code, message = code) { super(message); this.code = code; }
}
