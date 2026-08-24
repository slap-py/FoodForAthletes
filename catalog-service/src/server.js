import http from "node:http";
import { labelNutritionSource, manufacturerNutrition, mealClarifications, nutritionPlausibilityIssue, NutritionSourceError, sourceIngredient, totals } from "./nutrition.js";
import { namedMenuProducts, productIngredient } from "./menuProducts.js";

const credentials = { foodDataCentralKey: process.env.USDA_FOODDATA_API_KEY, openAIKey: process.env.OPENAI_API_KEY };
const mealAnalysisCache = new Map();
const MEAL_ANALYSIS_CACHE_TTL_MS = 15 * 60 * 1000;
const MEAL_ANALYSIS_CACHE_MAX_ENTRIES = 128;
// The general analysis model is text-first.  A request containing input_image
// must use the separate vision-capable model; otherwise an upstream model
// validation error is surfaced to iOS as a generic 5xx outage.
const defaultMealModel = process.env.OPENAI_MODEL ?? "gpt-5.6-terra";
const defaultVisionModel = process.env.OPENAI_VISION_MODEL ?? process.env.OPENAI_PHOTO_MODEL ?? "gpt-5.4-mini";

export const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    response.setHeader("content-type", "application/json; charset=utf-8");
    response.setHeader("cache-control", "no-store");

    if (request.method === "POST" && url.pathname === "/v1/meal-analysis") {
      const input = await requestBody(request);
      return json(response, 200, await withTimeout(cachedMealAnalysis(input), 65_000));
    }
    if (request.method === "POST" && url.pathname === "/v1/transcribe") return json(response, 200, await transcribe(await requestBody(request)));
    if (request.method === "POST" && url.pathname === "/v1/photo-foods") return json(response, 200, await detectFoods(await requestBody(request)));
    return json(response, 404, { error: "route_not_found" });
  } catch (error) {
    const status = error instanceof ServiceError && error.code === "service_not_configured" ? 503 : error instanceof NutritionSourceError ? 422 : 502;
    return json(response, status, { error: error instanceof Error ? error.message : "service_request_failed" });
  }
});

async function cachedMealAnalysis(input) {
  // Photos are intentionally excluded: caching large base64 payloads would
  // retain sensitive image data. Text-only repeated logs can safely share one
  // short-lived result and should not race through separate provider lookups.
  const hasPhotos = asArray(input.photosBase64).some(Boolean);
  if (hasPhotos) return analyzeMeal(input);
  const key = JSON.stringify({
    description: normalizeForCache(input.description),
    identifiedFoods: asArray(input.identifiedFoods).map(normalizeForCache).filter(Boolean).sort(),
    allowClarifications: input.allowClarifications === true,
    clarificationRound: clarificationRound(input),
    clarificationAnswers: sanitizeClarificationAnswers(input.clarificationAnswers)
  });
  sweepCache(mealAnalysisCache, MEAL_ANALYSIS_CACHE_MAX_ENTRIES);
  const cached = mealAnalysisCache.get(key);
  if (cached?.expiresAt > Date.now()) return cached.value;
  const value = analyzeMeal(input);
  mealAnalysisCache.set(key, { value, expiresAt: Date.now() + MEAL_ANALYSIS_CACHE_TTL_MS });
  try {
    return await value;
  } catch (error) {
    if (mealAnalysisCache.get(key)?.value === value) mealAnalysisCache.delete(key);
    throw error;
  }
}

async function analyzeMeal(input) {
  requireOpenAI();
  const description = String(input.description ?? "").trim();
  const identifiedFoods = [...new Set(asArray(input.identifiedFoods).map(food => String(food).trim()).filter(Boolean))].slice(0, 12);
  const clarificationAnswers = sanitizeClarificationAnswers(input.clarificationAnswers);
  const content = [{
    type: "input_text",
    text: [
      `Meal description: ${description || "(none)"}`,
      `Foods identified during photo review: ${identifiedFoods.length ? identifiedFoods.join(", ") : "(none)"}`,
      `Captured at: ${String(input.capturedAt ?? "") || "(not supplied)"} (${String(input.timeZoneIdentifier ?? "") || "timezone not supplied"})`,
      `User clarification answers: ${Object.keys(clarificationAnswers).length ? JSON.stringify(clarificationAnswers) : "(none)"}`
    ].join("\n\n")
  }];
  for (const [index, photo] of asArray(input.photosBase64).slice(0, 3).entries()) addImage(content, photo, `PHOTO ${index + 1} — determine whether this is food, packaging, or a nutrition label, then use it accordingly.`, "high");

  const interpretation = await structuredResponse({
    model: modelForMealAnalysis(input), reasoning: "low", content,
    timeoutMs: 30_000,
    instructions: "Identify only foods at the level the person ordered or ate. Foods identified during photo review are explicit user-visible hints: use them together with the photos and description, correct them only when the image clearly contradicts them, and do not discard them silently. Treat consumer descriptions as approximate: resolve ordinary synonyms, abbreviated flavor names, and remembered marketing names to a searchable product name, but do not silently choose between materially different products. Apply any user clarification answers as authoritative and re-derive the whole estimate from them: when an answer names a product, copy that product name verbatim into the ingredient name including any size, weight, or flavor qualifier, and recompute grams from the product the user chose rather than from the earlier guess. A named branded restaurant/menu product or packaged product MUST be exactly one branded ingredient and must never be split into recipe components. grams MUST be the total estimated weight actually consumed, not the weight of one unit: multiply an explicit count by the per-item weight (for example, two 48 g pastries means grams=96). quantity is the number of discrete units eaten; use 1 when not applicable or unknown. quantityUnit is a singular food unit such as pastry, bar, slice, or sandwich, or null when not applicable. quantityWasExplicit is true only when the user supplied the count. amountConfidence is low when the amount or per-unit weight is materially uncertain. When a photo shows a nutrition facts panel for one of these foods, that panel is the final word on that food's nutrition: transcribe it into that ingredient's labelNutrition exactly as printed — servingLabel and servingGrams describe one labeled serving, servingsConsumed is how many of those servings the person ate, and the nutrient values are per one labeled serving with carbohydrates being Total Carbohydrate. Use null for a nutrient the panel does not list. Set labelNutrition to null for every food with no panel in the photos, and never transcribe a panel onto a food it does not belong to. Keep the ingredient name as the searchable product or food name without putting the count into it. Only split an unbranded homemade/composed meal into familiar top-level components. When such a component is itself an assembly of distinct foods rather than a single food with a reliable composition record — a street taco, a burrito, a sandwich made to order, a salad — split it into the ingredients it is built from (for example three carne asada street tacos become corn tortillas, grilled beef, onion, and cilantro with per-ingredient grams). A packaged or restaurant-menu product with a real nutrition panel is never split this way. Infer brands only when visible, explicitly named, or unambiguous from a protected trademark such as Pop-Tarts. Return no duplicate, speculative, or unrelated ingredients.",
    name: "meal_ingredients", schema: ingredientSchema
  });
  const mealIngredients = applyConfirmedIdentities(
    preserveNamedProducts(description, interpretation.ingredients),
    clarificationAnswers
  );
  if (!mealIngredients.length) throw new ServiceError("no_recognized_food");
  const limitedMealIngredients = mealIngredients.slice(0, 12);
  let ingredients = await mapWithConcurrency(limitedMealIngredients, 3, ingredient =>
    labelNutritionSource(ingredient) ?? sourceIngredient(ingredient, credentials, manufacturerLookup)
  );
  let nutrients = totals(ingredients);
  let verification = await verifyNutrition(interpretation.title, ingredients, nutrients);
  if (!verification.isPlausible) {
    // A photographed panel is the user's own evidence; never research over it.
    const indexes = verificationIndexes(verification, ingredients.length)
      .filter(index => ingredients[index]?.sourceTier !== "label");
    const replacements = await mapWithConcurrency(indexes, 2, async index => {
      try {
        return await manufacturerLookup(limitedMealIngredients[index], {
          priorResult: ingredients[index],
          verificationIssue: verification.reason,
          requireCorroboration: true
        });
      } catch {
        return null;
      }
    });
    let replacementCount = 0;
    for (const [offset, index] of indexes.entries()) {
      const replacement = replacements[offset];
      if (!replacement || nutritionPlausibilityIssue(replacement.nutrients, positiveNumber(limitedMealIngredients[index]?.grams, 100))) continue;
      ingredients[index] = replacement;
      replacementCount += 1;
    }
    if (replacementCount > 0) {
      nutrients = totals(ingredients);
      verification = await verifyNutrition(interpretation.title, ingredients, nutrients, verification.reason);
    }
  }
  if (!verification.isPlausible) throw new ServiceError(`nutrition_verification_failed: ${verification.reason}`);
  const clarifications = input.allowClarifications === true && clarificationRound(input) < 2
    ? mealClarifications(limitedMealIngredients, ingredients, clarificationAnswers)
    : [];
  return {
    status: "complete",
    title: interpretation.title,
    ...nutrients,
    assumptions: interpretation.assumptions,
    foods: ingredients.map(item => ({
      name: item.name,
      portion: item.portion,
      sourceName: item.sourceName,
      sourceID: item.sourceID,
      sourceTier: item.sourceTier,
      // Per-food macros so the app can show where a meal's total came from.
      calories: item.nutrients?.calories ?? null,
      carbohydrates: item.nutrients?.carbohydrates ?? null,
      protein: item.nutrients?.protein ?? null,
      fat: item.nutrients?.fat ?? null
    })),
    clarifications,
    analysisVersion: "meal-level-sourced-v6",
    catalogVersion: "bounded USDA FoodData Central; Open Food Facts; AI web research; deterministic serving-unit checks; targeted GPT sanity check and repair"
  };
}

async function verifyNutrition(title, ingredients, nutrients, priorIssue = null) {
  return structuredResponse({
    model: process.env.OPENAI_VERIFY_MODEL ?? "gpt-5.4-mini", reasoning: "medium",
    timeoutMs: 20_000,
    content: [{ type: "input_text", text: JSON.stringify({ title, ingredients, nutrients, priorIssue }) }],
    instructions: "Perform a conservative nutrition sanity check after a food log. Flag clearly implausible source or unit errors, especially values copied per 100 g but presented as one smaller serving. Use the source and corroboration metadata as evidence. An ingredient whose sourceTier is \"label\" was read from a photograph of the product's own nutrition panel and is authoritative — never flag it. Do not invent or modify nutrients. When implausible, return the zero-based indexes of only the ingredients that need new source research; when plausible, return an empty array.",
    name: "nutrition_sanity_check", schema: verificationSchema
  });
}

async function detectFoods(input) {
  requireOpenAI();
  const photo = String(input.photoBase64 ?? "");
  if (!photo) throw new ServiceError("invalid_photo");
  const result = await structuredResponse({
    model: defaultVisionModel,
    reasoning: "low",
    timeoutMs: 30_000,
    content: [
      { type: "input_text", text: "what foods do you see in the photo" },
      { type: "input_image", image_url: `data:image/jpeg;base64,${photo}`, detail: "high" }
    ],
    instructions: "List visible edible foods and drinks. Use short, specific names and do not include plates, utensils, packaging, tables, or other non-food objects. Prefer a useful generic identification such as cooked steak over returning an empty list when the exact cut or preparation is uncertain. Set isNutritionLabel true when the photo is mainly a printed nutrition facts panel rather than food; in that case list only the product the panel belongs to, and return an empty list when the product name is not legible. Return an empty list only when no edible item is visible.",
    name: "photo_foods",
    schema: photoFoodsSchema
  });
  const foods = [...new Set(asArray(result.foods).map(food => String(food).trim()).filter(Boolean))].slice(0, 12);
  return { foods, isNutritionLabel: result.isNutritionLabel === true };
}

async function manufacturerLookup(ingredient, context = null) {
  const foodName = [ingredient.brand, ingredient.name].filter(Boolean).join(" ");
  const result = await structuredResponse({
    model: process.env.OPENAI_MANUFACTURER_MODEL ?? "gpt-5.4-nano", reasoning: "medium",
    timeoutMs: 35_000,
    content: [{ type: "input_text", text: JSON.stringify({ request: `Find nutrition facts for ${foodName}.`, requestedGrams: ingredient.grams, foodKind: ingredient.kind, repairContext: context }) }],
    instructions: "Use web search to resolve the food after direct USDA and Open Food Facts lookups were unavailable, insufficient, or suspect. The user's title may be approximate, abbreviated, or a remembered flavor description; identify a likely marketed product when the brand, product family, flavor semantics, and region support it. Report matchConfidence from 0 to 1 and set identityNeedsConfirmation=true when a reasonable person could mean a materially different product. For branded foods prefer the brand's official nutrition or product page, then another reputable product database. For generic foods prefer an authoritative composition database. Use one primary source and, when available, up to two independent sources to corroborate identity, labeled serving count, serving grams, calories, and macros. Never invent data, average conflicts, or split a named product into ingredients. Explicitly identify whether nutrients are per serving or per 100 g. servingGrams and servingCount describe one labeled serving; servingUnit is singular. Do not confuse a source's labeled serving with the amount the user ate. carbohydrates must be Total Carbohydrate exactly. Use null for an optional micronutrient not reported. Return found=false unless identity and complete calories, carbs, protein, and fat are sufficiently supported. If repairContext is present, independently investigate the suspected result rather than repeating it.",
    tools: [{ type: "web_search" }], name: "manufacturer_nutrition", schema: manufacturerSchema
  });
  return manufacturerNutrition(ingredient, result);
}

async function transcribe(input) {
  requireOpenAI();
  const audio = Buffer.from(String(input.audioBase64 ?? ""), "base64");
  if (!audio.length) throw new ServiceError("invalid_audio");
  const form = new FormData();
  form.set("file", new Blob([audio], { type: input.mimeType ?? "audio/m4a" }), "meal-audio.m4a");
  form.set("model", "whisper-1");
  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", { method: "POST", headers: { Authorization: `Bearer ${credentials.openAIKey}` }, body: form });
  const payload = await response.json();
  if (!response.ok) throw new ServiceError(payload?.error?.message ?? "openai_transcription_failed");
  return { text: String(payload?.text ?? "") };
}

async function structuredResponse({ model, reasoning, content, instructions, tools, name, schema, timeoutMs = 45_000 }) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST", headers: { Authorization: `Bearer ${credentials.openAIKey}`, "content-type": "application/json" }, signal: controller.signal,
      body: JSON.stringify({ model, reasoning: { effort: reasoning }, store: false, instructions, tools, input: [{ role: "user", content }], text: { format: { type: "json_schema", name, strict: true, schema } } })
    });
    const payload = await response.json();
    if (!response.ok) throw new ServiceError(payload?.error?.message ?? "openai_analysis_failed");
    const output = payload.output_text ?? payload.output?.flatMap(item => item.content ?? []).find(item => item.type === "output_text")?.text;
    if (!output) throw new ServiceError("openai_analysis_failed");
    return JSON.parse(output);
  } catch (error) {
    if (error?.name === "AbortError") throw new ServiceError("analysis_timed_out");
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function addImage(content, base64, label, detail) {
  if (typeof base64 !== "string" || !base64) return;
  content.push({ type: "input_text", text: label }, { type: "input_image", image_url: `data:image/jpeg;base64,${base64}`, detail });
}

// A confirmed identity is the user's own answer, so it replaces whatever product
// name the interpretation model paraphrased. The nutrition search keys off the
// name, and a paraphrase loses the size or flavor qualifier that distinguishes
// two real products (a 2 oz sandwich from a 2.6 oz one).
function applyConfirmedIdentities(ingredients, answers) {
  const confirmed = Object.entries(answers ?? {})
    .filter(([key]) => key.endsWith("_identity"))
    .map(([, value]) => String(value).replace(/^The intended product is\s*/i, "").replace(/\.\s*$/, "").trim())
    .filter(Boolean);
  if (!confirmed.length) return ingredients;

  return ingredients.map(ingredient => {
    const current = [ingredient.brand, ingredient.name].filter(Boolean).join(" ");
    const match = confirmed.find(name => sharesMostWords(current, name));
    return match ? { ...ingredient, name: match, brand: null } : ingredient;
  });
}

function sharesMostWords(value, other) {
  const valueWords = words(value);
  const otherWords = words(other);
  if (!valueWords.size || !otherWords.size) return false;
  return [...valueWords].filter(word => otherWords.has(word)).length / valueWords.size >= 0.5;
}

function preserveNamedProducts(description, candidates) {
  const products = namedMenuProducts(description);
  if (!products.length) return candidates;

  const descriptionWords = words(description);
  const productWords = new Set(products.flatMap(product => [...words(product.name)]));
  const extras = candidates.filter(candidate => {
    const candidateWords = words([candidate.brand, candidate.name].filter(Boolean).join(" "));
    // Keep another distinct food only when it is explicitly mentioned outside
    // the named menu product, e.g. "the sandwich and a chocolate croissant."
    return [...candidateWords].some(word => descriptionWords.has(word) && !productWords.has(word));
  });

  return [...products.map(product => productIngredient(product, description)), ...extras];
}

async function withTimeout(promise, timeoutMs) {
  let timeout;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new ServiceError("analysis_timed_out")), timeoutMs);
      })
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function words(value) {
  return new Set(String(value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(" ")
    .filter(Boolean));
}

function normalizeForCache(value) {
  return String(value ?? "").trim().toLowerCase().replace(/\s+/g, " ");
}

const labelNutritionProperties = {
  servingLabel: { type: "string" },
  servingGrams: { type: ["number", "null"] },
  servingsConsumed: { type: "number", exclusiveMinimum: 0 },
  calories: { type: "number" },
  carbohydrates: { type: "number" },
  protein: { type: "number" },
  fat: { type: "number" },
  fiber: { type: ["number", "null"] },
  calcium: { type: ["number", "null"] },
  iron: { type: ["number", "null"] },
  magnesium: { type: ["number", "null"] },
  potassium: { type: ["number", "null"] },
  sodium: { type: ["number", "null"] },
  vitaminD: { type: ["number", "null"] }
};
const ingredientProperties = {
  name: { type: "string" },
  brand: { type: ["string", "null"] },
  kind: { type: "string", enum: ["generic", "branded"] },
  grams: { type: "number", exclusiveMinimum: 0 },
  quantity: { type: "number", minimum: 0 },
  quantityUnit: { type: ["string", "null"] },
  quantityWasExplicit: { type: "boolean" },
  amountConfidence: { type: "string", enum: ["high", "medium", "low"] },
  labelNutrition: {
    type: ["object", "null"],
    additionalProperties: false,
    properties: labelNutritionProperties,
    required: Object.keys(labelNutritionProperties)
  }
};
const ingredientSchema = {
  type: "object", additionalProperties: false,
  properties: {
    title: { type: "string" },
    assumptions: { type: "string" },
    ingredients: { type: "array", items: { type: "object", additionalProperties: false, properties: ingredientProperties, required: Object.keys(ingredientProperties) } }
  },
  required: ["title", "assumptions", "ingredients"]
};
const verificationSchema = { type: "object", additionalProperties: false, properties: { isPlausible: { type: "boolean" }, reason: { type: "string" }, ingredientIndexesToRecheck: { type: "array", items: { type: "integer" } } }, required: ["isPlausible", "reason", "ingredientIndexesToRecheck"] };
const photoFoodsSchema = { type: "object", additionalProperties: false, properties: { foods: { type: "array", items: { type: "string" } }, isNutritionLabel: { type: "boolean" } }, required: ["foods", "isNutritionLabel"] };
const coreNutrientKeys = new Set(["calories", "carbohydrates", "protein", "fat"]);
const nutrientProperties = Object.fromEntries(["calories", "carbohydrates", "protein", "fat", "fiber", "calcium", "iron", "magnesium", "potassium", "sodium", "vitaminD"].map(key => [key, { type: coreNutrientKeys.has(key) ? "number" : ["number", "null"] }]));
const manufacturerSchema = { type: "object", additionalProperties: false, properties: { found: { type: "boolean" }, name: { type: "string" }, sourceURL: { type: "string" }, sourceName: { type: "string" }, matchConfidence: { type: "number" }, identityNeedsConfirmation: { type: "boolean" }, servingLabel: { type: "string" }, servingGrams: { type: ["number", "null"] }, servingCount: { type: ["number", "null"] }, servingUnit: { type: ["string", "null"] }, nutritionBasis: { type: "string", enum: ["per_serving", "per_100g"] }, nutrients: { type: "object", additionalProperties: false, properties: nutrientProperties, required: Object.keys(nutrientProperties) }, evidence: { type: "array", items: { type: "object", additionalProperties: false, properties: { sourceName: { type: "string" }, sourceURL: { type: "string" } }, required: ["sourceName", "sourceURL"] } } }, required: ["found", "name", "sourceURL", "sourceName", "matchConfidence", "identityNeedsConfirmation", "servingLabel", "servingGrams", "servingCount", "servingUnit", "nutritionBasis", "nutrients", "evidence"] };

function verificationIndexes(verification, ingredientCount) {
  return [...new Set(asArray(verification.ingredientIndexesToRecheck)
    .map(Number)
    .filter(index => Number.isInteger(index) && index >= 0 && index < ingredientCount))]
    .slice(0, 2);
}

function sanitizeClarificationAnswers(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).slice(0, 4).map(([key, answer]) => [String(key).slice(0, 80), String(answer).slice(0, 300)]));
}

function requestBody(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on("data", chunk => {
      size += chunk.length;
      if (size > 20 * 1024 * 1024) return reject(new ServiceError("request_too_large"));
      chunks.push(chunk);
    });
    request.on("end", () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch { reject(new ServiceError("invalid_request")); } });
    request.on("error", reject);
  });
}

function json(response, status, value) { response.writeHead(status); response.end(JSON.stringify(value)); }
function asArray(value) { return Array.isArray(value) ? value : value ? [value] : []; }
function hasPhotos(input) { return asArray(input?.photosBase64).some(Boolean); }
export function modelForMealAnalysis(input) { return hasPhotos(input) ? defaultVisionModel : defaultMealModel; }
function positiveNumber(value, fallback) { const parsed = Number(value); return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback; }
function clarificationRound(input) { return Math.min(2, Math.max(0, Math.floor(Number(input?.clarificationRound) || 0))); }
async function mapWithConcurrency(items, limit, operation) {
  const results = new Array(items.length);
  let nextIndex = 0;
  async function worker() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await operation(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}
function sweepCache(cache, maximumEntries) {
  const now = Date.now();
  for (const [key, entry] of cache) if (entry?.expiresAt <= now) cache.delete(key);
  while (cache.size >= maximumEntries) cache.delete(cache.keys().next().value);
}
function requireOpenAI() { if (!credentials.openAIKey) throw new ServiceError("service_not_configured"); }
class ServiceError extends Error { constructor(code) { super(code); this.code = code; } }
