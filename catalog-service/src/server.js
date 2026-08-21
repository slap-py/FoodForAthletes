import http from "node:http";
import { manufacturerNutrition, NutritionSourceError, sourceIngredient, totals } from "./nutrition.js";
import { namedMenuProducts, productIngredient } from "./menuProducts.js";

const credentials = { foodDataCentralKey: process.env.USDA_FOODDATA_API_KEY, openAIKey: process.env.OPENAI_API_KEY };

export const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    response.setHeader("content-type", "application/json; charset=utf-8");
    response.setHeader("cache-control", "no-store");

    if (request.method === "POST" && url.pathname === "/v1/meal-analysis") {
      const input = await requestBody(request);
      return json(response, 200, await analyzeMeal(input));
    }
    if (request.method === "POST" && url.pathname === "/v1/transcribe") return json(response, 200, await transcribe(await requestBody(request)));
    return json(response, 404, { error: "route_not_found" });
  } catch (error) {
    const status = error instanceof ServiceError && error.code === "service_not_configured" ? 503 : error instanceof NutritionSourceError ? 422 : 502;
    return json(response, status, { error: error instanceof Error ? error.message : "service_request_failed" });
  }
});

async function analyzeMeal(input) {
  requireOpenAI();
  const description = String(input.description ?? "").trim();
  const content = [{
    type: "input_text",
    text: [
      `Meal description: ${description || "(none)"}`,
      `Captured at: ${String(input.capturedAt ?? "") || "(not supplied)"} (${String(input.timeZoneIdentifier ?? "") || "timezone not supplied"})`
    ].join("\n\n")
  }];
  for (const [index, photo] of asArray(input.photosBase64).slice(0, 3).entries()) addImage(content, photo, `PHOTO ${index + 1} — determine whether this is food, packaging, or a nutrition label, then use it accordingly.`, "high");

  const interpretation = await structuredResponse({
    model: process.env.OPENAI_MODEL ?? "gpt-5.6-terra", reasoning: "low", content,
    instructions: "Identify only foods at the level the person ordered or ate. A named branded restaurant/menu product or packaged product (for example, a Starbucks Double-Smoked Bacon, Cheddar & Egg Sandwich) MUST be exactly one branded ingredient with its product name and brand, never split into bread, egg, bacon, sauces, or unrelated search-like foods. Only split an unbranded homemade/composed meal into familiar top-level components; never return recipe subcomponents such as flour inside a bun. Infer brands only when visible or explicitly named. Return no duplicate, speculative, or unrelated ingredients.",
    name: "meal_ingredients", schema: ingredientSchema
  });
  const mealIngredients = preserveNamedProducts(description, interpretation.ingredients);
  if (!mealIngredients.length) throw new ServiceError("no_recognized_food");
  const ingredients = await Promise.all(mealIngredients.slice(0, 12).map(ingredient => sourceIngredient(ingredient, credentials, manufacturerLookup)));
  const nutrients = totals(ingredients);
  const verification = await structuredResponse({
    model: process.env.OPENAI_VERIFY_MODEL ?? "gpt-5.4-mini", reasoning: "medium",
    content: [{ type: "input_text", text: JSON.stringify({ title: interpretation.title, ingredients, nutrients }) }],
    instructions: "Perform a conservative nutrition sanity check after a food log. Flag clearly implausible source or unit errors, such as a single snack being 10,000 calories. Do not invent or modify nutrients.",
    name: "nutrition_sanity_check", schema: verificationSchema
  });
  if (!verification.isPlausible) throw new ServiceError(`nutrition_verification_failed: ${verification.reason}`);
  return { title: interpretation.title, ...nutrients, assumptions: interpretation.assumptions, foods: ingredients.map(item => ({ name: item.name, portion: item.portion, sourceName: item.sourceName, sourceID: item.sourceID })), analysisVersion: "meal-level-sourced-v2", catalogVersion: "USDA FoodData Central; Open Food Facts; official manufacturer and trusted menu-data fallback; GPT sanity check" };
}

async function manufacturerLookup(ingredient) {
  const result = await structuredResponse({
    model: process.env.OPENAI_MANUFACTURER_MODEL ?? "gpt-5.4-nano", reasoning: "medium",
    content: [{ type: "input_text", text: `Find the manufacturer nutrition facts for ${[ingredient.brand, ingredient.name].filter(Boolean).join(" ")}.` }],
    instructions: "Use web search only to resolve this exact branded product as one serving. Source preference: (1) the brand or restaurant's official nutrition/product page, (2) USDA FoodData Central or Open Food Facts only when the exact product is confirmed, (3) FastFoodNutrition.org or a reputable published U.S. menu dataset when the official page is unavailable. Kaggle may be used only when a dataset clearly identifies the brand, product, and serving. Never invent data, combine partial results, or split the product into ingredients. Return the Nutrition Facts for the listed serving; serving grams are optional. carbohydrates must be the Nutrition Facts Total Carbohydrate value exactly. Sugars and dietary fiber are components of total carbohydrate, so never add either one to carbohydrates; return fiber separately. If the exact product and complete calories, carbs, protein, and fat cannot be verified, return found=false.",
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

const ingredientSchema = {
  type: "object", additionalProperties: false,
  properties: {
    title: { type: "string" },
    assumptions: { type: "string" },
    ingredients: { type: "array", items: { type: "object", additionalProperties: false, properties: { name: { type: "string" }, brand: { type: ["string", "null"] }, kind: { type: "string", enum: ["generic", "branded"] }, grams: { type: "number" } }, required: ["name", "brand", "kind", "grams"] } }
  },
  required: ["title", "assumptions", "ingredients"]
};
const verificationSchema = { type: "object", additionalProperties: false, properties: { isPlausible: { type: "boolean" }, reason: { type: "string" } }, required: ["isPlausible", "reason"] };
const manufacturerSchema = { type: "object", additionalProperties: false, properties: { found: { type: "boolean" }, name: { type: "string" }, sourceURL: { type: "string" }, sourceName: { type: "string" }, servingLabel: { type: "string" }, servingGrams: { type: ["number", "null"] }, nutrientsPerServing: { type: "object", additionalProperties: false, properties: Object.fromEntries(["calories", "carbohydrates", "protein", "fat", "fiber", "calcium", "iron", "magnesium", "potassium", "sodium", "vitaminD"].map(key => [key, { type: "number" }])), required: ["calories", "carbohydrates", "protein", "fat", "fiber", "calcium", "iron", "magnesium", "potassium", "sodium", "vitaminD"] } }, required: ["found", "name", "sourceURL", "sourceName", "servingLabel", "servingGrams", "nutrientsPerServing"] };

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
