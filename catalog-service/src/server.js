import http from "node:http";
import { manufacturerNutrition, mealClarifications, nutritionPlausibilityIssue, NutritionSourceError, sourceIngredient, totals } from "./nutrition.js";
import { namedMenuProducts, productIngredient } from "./menuProducts.js";

const credentials = { foodDataCentralKey: process.env.USDA_FOODDATA_API_KEY, openAIKey: process.env.OPENAI_API_KEY };
const mealAnalysisCache = new Map();
const MEAL_ANALYSIS_CACHE_TTL_MS = 15 * 60 * 1000;

export const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    response.setHeader("content-type", "application/json; charset=utf-8");
    response.setHeader("cache-control", "no-store");

    if (request.method === "POST" && url.pathname === "/v1/meal-analysis") {
      const input = await requestBody(request);
      return json(response, 200, await cachedMealAnalysis(input));
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
    clarificationAnswers: sanitizeClarificationAnswers(input.clarificationAnswers)
  });
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
    model: process.env.OPENAI_MODEL ?? "gpt-5.6-terra", reasoning: "low", content,
    instructions: "Identify only foods at the level the person ordered or ate. Foods identified during photo review are explicit user-visible hints: use them together with the photos and description, correct them only when the image clearly contradicts them, and do not discard them silently. Treat consumer descriptions as approximate: resolve ordinary synonyms, abbreviated flavor names, and remembered marketing names to a searchable product name, but do not silently choose between materially different products. Apply any user clarification answers as authoritative. A named branded restaurant/menu product or packaged product MUST be exactly one branded ingredient and must never be split into recipe components. grams MUST be the total estimated weight actually consumed, not the weight of one unit: multiply an explicit count by the per-item weight (for example, two 48 g pastries means grams=96). quantity is the number of discrete units eaten; use 1 when not applicable or unknown. quantityUnit is a singular food unit such as pastry, bar, slice, or sandwich, or null when not applicable. quantityWasExplicit is true only when the user supplied the count. amountConfidence is low when the amount or per-unit weight is materially uncertain. Keep the ingredient name as the searchable product or food name without putting the count into it. Only split an unbranded homemade/composed meal into familiar top-level components. Infer brands only when visible, explicitly named, or unambiguous from a protected trademark such as Pop-Tarts. Return no duplicate, speculative, or unrelated ingredients.",
    name: "meal_ingredients", schema: ingredientSchema
  });
  const mealIngredients = preserveNamedProducts(description, interpretation.ingredients);
  if (!mealIngredients.length) throw new ServiceError("no_recognized_food");
  const limitedMealIngredients = mealIngredients.slice(0, 12);
  let ingredients = await Promise.all(limitedMealIngredients.map(ingredient => sourceIngredient(ingredient, credentials, manufacturerLookup)));
  ingredients = await supplementServingEvidence(limitedMealIngredients, ingredients);
  if (input.allowClarifications === true) {
    const questions = mealClarifications(limitedMealIngredients, ingredients, clarificationAnswers);
    if (questions.length) return { status: "needs_clarification", questions };
  }
  let nutrients = totals(ingredients);
  let verification = await verifyNutrition(interpretation.title, ingredients, nutrients);
  if (!verification.isPlausible) {
    const indexes = verificationIndexes(verification, ingredients.length);
    const replacements = await Promise.all(indexes.map(async index => {
      try {
        return await manufacturerLookup(limitedMealIngredients[index], {
          priorResult: ingredients[index],
          verificationIssue: verification.reason,
          requireCorroboration: true
        });
      } catch {
        return null;
      }
    }));
    let replacementCount = 0;
    for (const [offset, index] of indexes.entries()) {
      const replacement = replacements[offset];
      if (!replacement || nutritionPlausibilityIssue(replacement.nutrients, limitedMealIngredients[index].grams)) continue;
      ingredients[index] = replacement;
      replacementCount += 1;
    }
    if (replacementCount > 0) {
      nutrients = totals(ingredients);
      verification = await verifyNutrition(interpretation.title, ingredients, nutrients, verification.reason);
    }
  }
  if (!verification.isPlausible) throw new ServiceError(`nutrition_verification_failed: ${verification.reason}`);
  return { status: "complete", title: interpretation.title, ...nutrients, assumptions: interpretation.assumptions, foods: ingredients.map(item => ({ name: item.name, portion: item.portion, sourceName: item.sourceName, sourceID: item.sourceID })), analysisVersion: "meal-level-sourced-v4", catalogVersion: "USDA FoodData Central; fuzzy Open Food Facts matching; AI identity and serving corroboration; deterministic unit checks; GPT sanity check and repair" };
}

async function supplementServingEvidence(requestedIngredients, sourcedIngredients) {
  return Promise.all(sourcedIngredients.map(async (item, index) => {
    const requested = requestedIngredients[index];
    if (requested?.kind !== "branded" || requested.quantityWasExplicit !== true || item.sourceName !== "Open Food Facts") return item;
    try {
      const verified = await manufacturerLookup(requested, { priorResult: item, verifyServingOnly: true, requireCorroboration: true });
      if (!verified?.referenceServing?.grams) return item;
      return {
        ...item,
        referenceServing: verified.referenceServing,
        servingVerifiedBy: { sourceName: verified.sourceName, sourceID: verified.sourceID },
        corroboratedBy: [...asArray(item.corroboratedBy), { sourceName: verified.sourceName, sourceURL: verified.sourceID }]
      };
    } catch {
      return item;
    }
  }));
}

async function verifyNutrition(title, ingredients, nutrients, priorIssue = null) {
  return structuredResponse({
    model: process.env.OPENAI_VERIFY_MODEL ?? "gpt-5.4-mini", reasoning: "medium",
    content: [{ type: "input_text", text: JSON.stringify({ title, ingredients, nutrients, priorIssue }) }],
    instructions: "Perform a conservative nutrition sanity check after a food log. Flag clearly implausible source or unit errors, especially values copied per 100 g but presented as one smaller serving. Use the source and corroboration metadata as evidence. Do not invent or modify nutrients. When implausible, return the zero-based indexes of only the ingredients that need new source research; when plausible, return an empty array.",
    name: "nutrition_sanity_check", schema: verificationSchema
  });
}

async function detectFoods(input) {
  requireOpenAI();
  const photo = String(input.photoBase64 ?? "");
  if (!photo) throw new ServiceError("invalid_photo");
  const result = await structuredResponse({
    model: process.env.OPENAI_PHOTO_MODEL ?? "gpt-5.4-mini",
    reasoning: "low",
    content: [
      { type: "input_text", text: "what foods do you see in the photo" },
      { type: "input_image", image_url: `data:image/jpeg;base64,${photo}`, detail: "high" }
    ],
    instructions: "List visible edible foods and drinks. Use short, specific names and do not include plates, utensils, packaging, tables, or other non-food objects. Prefer a useful generic identification such as cooked steak over returning an empty list when the exact cut or preparation is uncertain. Return an empty list only when no edible item is visible.",
    name: "photo_foods",
    schema: photoFoodsSchema
  });
  const foods = [...new Set(asArray(result.foods).map(food => String(food).trim()).filter(Boolean))].slice(0, 12);
  return { foods };
}

async function manufacturerLookup(ingredient, context = null) {
  const foodName = [ingredient.brand, ingredient.name].filter(Boolean).join(" ");
  const result = await structuredResponse({
    model: process.env.OPENAI_MANUFACTURER_MODEL ?? "gpt-5.4-nano", reasoning: "medium",
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

async function structuredResponse({ model, reasoning, content, instructions, tools, name, schema }) {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST", headers: { Authorization: `Bearer ${credentials.openAIKey}`, "content-type": "application/json" },
    body: JSON.stringify({ model, reasoning: { effort: reasoning }, store: false, instructions, tools, input: [{ role: "user", content }], text: { format: { type: "json_schema", name, strict: true, schema } } })
  });
  const payload = await response.json();
  if (!response.ok) throw new ServiceError(payload?.error?.message ?? "openai_analysis_failed");
  const output = payload.output_text ?? payload.output?.flatMap(item => item.content ?? []).find(item => item.type === "output_text")?.text;
  if (!output) throw new ServiceError("openai_analysis_failed");
  return JSON.parse(output);
}

function addImage(content, base64, label, detail) {
  if (typeof base64 !== "string" || !base64) return;
  content.push({ type: "input_text", text: label }, { type: "input_image", image_url: `data:image/jpeg;base64,${base64}`, detail });
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

  return [...products.map(productIngredient), ...extras];
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

const ingredientSchema = {
  type: "object", additionalProperties: false,
  properties: {
    title: { type: "string" },
    assumptions: { type: "string" },
    ingredients: { type: "array", items: { type: "object", additionalProperties: false, properties: { name: { type: "string" }, brand: { type: ["string", "null"] }, kind: { type: "string", enum: ["generic", "branded"] }, grams: { type: "number" }, quantity: { type: "number" }, quantityUnit: { type: ["string", "null"] }, quantityWasExplicit: { type: "boolean" }, amountConfidence: { type: "string", enum: ["high", "medium", "low"] } }, required: ["name", "brand", "kind", "grams", "quantity", "quantityUnit", "quantityWasExplicit", "amountConfidence"] } }
  },
  required: ["title", "assumptions", "ingredients"]
};
const verificationSchema = { type: "object", additionalProperties: false, properties: { isPlausible: { type: "boolean" }, reason: { type: "string" }, ingredientIndexesToRecheck: { type: "array", items: { type: "integer" } } }, required: ["isPlausible", "reason", "ingredientIndexesToRecheck"] };
const photoFoodsSchema = { type: "object", additionalProperties: false, properties: { foods: { type: "array", items: { type: "string" } } }, required: ["foods"] };
const coreNutrientKeys = new Set(["calories", "carbohydrates", "protein", "fat"]);
const nutrientProperties = Object.fromEntries(["calories", "carbohydrates", "protein", "fat", "fiber", "calcium", "iron", "magnesium", "potassium", "sodium", "vitaminD"].map(key => [key, { type: coreNutrientKeys.has(key) ? "number" : ["number", "null"] }]));
const manufacturerSchema = { type: "object", additionalProperties: false, properties: { found: { type: "boolean" }, name: { type: "string" }, sourceURL: { type: "string" }, sourceName: { type: "string" }, matchConfidence: { type: "number" }, identityNeedsConfirmation: { type: "boolean" }, servingLabel: { type: "string" }, servingGrams: { type: ["number", "null"] }, servingCount: { type: ["number", "null"] }, servingUnit: { type: ["string", "null"] }, nutritionBasis: { type: "string", enum: ["per_serving", "per_100g"] }, nutrients: { type: "object", additionalProperties: false, properties: nutrientProperties, required: Object.keys(nutrientProperties) }, evidence: { type: "array", items: { type: "object", additionalProperties: false, properties: { sourceName: { type: "string" }, sourceURL: { type: "string" } }, required: ["sourceName", "sourceURL"] } } }, required: ["found", "name", "sourceURL", "sourceName", "matchConfidence", "identityNeedsConfirmation", "servingLabel", "servingGrams", "servingCount", "servingUnit", "nutritionBasis", "nutrients", "evidence"] };

function verificationIndexes(verification, ingredientCount) {
  const valid = [...new Set(asArray(verification.ingredientIndexesToRecheck)
    .map(Number)
    .filter(index => Number.isInteger(index) && index >= 0 && index < ingredientCount))];
  return valid.length ? valid : Array.from({ length: ingredientCount }, (_, index) => index);
}

function sanitizeClarificationAnswers(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).slice(0, 2).map(([key, answer]) => [String(key).slice(0, 80), String(answer).slice(0, 300)]));
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
function requireOpenAI() { if (!credentials.openAIKey) throw new ServiceError("service_not_configured"); }
class ServiceError extends Error { constructor(code) { super(code); this.code = code; } }
