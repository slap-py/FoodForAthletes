import { curatedMenuProduct } from "./menuProducts.js";

const USDA_API_URL = "https://api.nal.usda.gov/fdc/v1";
const OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/cgi/search.pl";
const ingredientCache = new Map();
const INGREDIENT_CACHE_TTL_MS = 30 * 60 * 1000;

export class NutritionSourceError extends Error {}

/**
 * Resolves a meal-level food, never recipe subcomponents. Branded restaurant
 * and packaged menu items are kept intact as one product. Every food follows
 * the same lookup hierarchy: USDA, Open Food Facts, then AI-assisted web
 * research. A checked-in exact manufacturer record can satisfy the final tier
 * without another web request.
 */
export async function sourceIngredient(ingredient, credentials, manufacturerLookup, request = fetch) {
  const cacheKey = JSON.stringify([
    ingredient.kind,
    normalize(ingredient.brand),
    normalize(ingredient.name),
    Math.round(positiveNumber(ingredient.grams, 100))
  ]);
  const cached = ingredientCache.get(cacheKey);
  if (cached?.expiresAt > Date.now()) return cached.value;

  // Cache the in-flight promise as well as its result. Two identical logs made
  // together should share the same provider result rather than race through
  // separate USDA/AI lookups and potentially select different records.
  const value = sourceIngredientUncached(ingredient, credentials, manufacturerLookup, request);
  ingredientCache.set(cacheKey, { value, expiresAt: Date.now() + INGREDIENT_CACHE_TTL_MS });
  try {
    return await value;
  } catch (error) {
    if (ingredientCache.get(cacheKey)?.value === value) ingredientCache.delete(cacheKey);
    throw error;
  }
}

async function sourceIngredientUncached(ingredient, credentials, manufacturerLookup, request) {
  const query = [ingredient.brand, ingredient.name].filter(Boolean).join(" ");
  const grams = positiveNumber(ingredient.grams, 100);
  const failures = [];

  const usda = await trySource("USDA", failures, () => usdaIngredient(
    query,
    grams,
    credentials.foodDataCentralKey,
    request,
    ingredient.kind === "branded" ? "Branded" : undefined
  ));
  if (isTrustworthyNutrition(usda, grams, failures)) return finalizeSourcedItem(usda, ingredient, grams);

  const off = await trySource("Open Food Facts", failures, () => openFoodFactsIngredient(query, grams, request));
  if (isTrustworthyNutrition(off, grams, failures)) return finalizeSourcedItem(off, ingredient, grams);

  if (ingredient.kind === "branded") {
    const curated = curatedMenuProduct(ingredient);
    const exactProduct = curated ? curatedProductNutrition(curated, grams) : null;
    if (isTrustworthyNutrition(exactProduct, grams, failures)) return finalizeSourcedItem(exactProduct, ingredient, grams);
  }

  const researched = await trySource("AI web research", failures, () => manufacturerLookup({ ...ingredient, grams }));
  if (isTrustworthyNutrition(researched, grams, failures)) return finalizeSourcedItem(researched, ingredient, grams);

  const error = new NutritionSourceError(`No trustworthy nutrition source found for: ${query}`);
  error.failures = failures;
  throw error;
}

async function usdaIngredient(query, grams, apiKey, request, dataType) {
  if (!apiKey) throw new NutritionSourceError("USDA_FOODDATA_API_KEY is not configured.");
  const foods = [];
  let completedSearch = false;
  let lastError;
  for (const searchQuery of usdaSearchQueries(query)) {
    const params = new URLSearchParams({ query: searchQuery, pageSize: "12", api_key: apiKey });
    if (dataType) params.set("dataType", dataType);
    try {
      const search = await requestJSON(request, `${USDA_API_URL}/foods/search?${params}`, undefined, "USDA search failed.");
      completedSearch = true;
      foods.push(...asArray(search?.foods));
      if (bestUsdaCandidates(foods, query, dataType)[0]?.score >= 0.9) break;
    } catch (error) {
      lastError = error;
    }
  }
  if (!completedSearch) throw lastError ?? new NutritionSourceError("USDA search failed.");

  // USDA occasionally returns a search hit whose detail record is temporarily
  // unavailable. Try the next deterministic candidate before abandoning USDA.
  for (const { food: candidate } of bestUsdaCandidates(foods, query, dataType).slice(0, 3)) {
    if (!candidate?.fdcId) continue;
    try {
      const food = await requestJSON(request, `${USDA_API_URL}/food/${candidate.fdcId}?api_key=${encodeURIComponent(apiKey)}`, undefined, "USDA food detail lookup failed.");
      const perPortion = usdaNutrients(food, grams);
      if (!perPortion || perPortion.calories <= 0) continue;
      const candidateName = food.description ?? candidate.description ?? query;
      return {
        name: candidateName,
        portion: portionLabel(grams, ingredientPortionHint(food)),
        sourceName: dataType ? "USDA FoodData Central — Branded" : "USDA FoodData Central",
        sourceID: String(candidate.fdcId),
        identityMatch: productIdentityMatch(query, candidateName, foods.map(item => item?.description), [candidateName, food?.brandOwner, food?.brandName].filter(Boolean).join(" ")),
        referenceServing: referenceServing(ingredientPortionHint(food), food?.servingSize, food?.servingSizeUnit),
        nutrients: perPortion
      };
    } catch (error) {
      lastError = error;
    }
  }
  if (lastError) throw lastError;
  return null;
}

function usdaNutrients(food, grams) {
  const label = food?.labelNutrients;
  const servingSize = positiveNumber(food?.servingSize, 0);
  if (label && servingSize > 0) {
    const scale = grams / servingSize;
    const values = {
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
    };
    return hasCoreNutrients(values) ? normalizeNutrients(values, scale) : null;
  }
  const values = Object.fromEntries(asArray(food?.foodNutrients).map(item => [String(item?.nutrient?.name ?? item?.nutrientName ?? "").toLowerCase(), item.amount]));
  const nutrients = {
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
  };
  return hasCoreNutrients(nutrients) ? normalizeNutrients(nutrients, grams / 100) : null;
}

async function openFoodFactsIngredient(query, grams, request) {
  const products = [];
  let completedSearch = false;
  for (const searchTerms of openFoodFactsSearchQueries(query)) {
    const params = new URLSearchParams({
      search_terms: searchTerms,
      search_simple: "1",
      action: "process",
      json: "1",
      page_size: "12",
      fields: "code,product_name,brands,nutriments,serving_size,serving_quantity,serving_quantity_unit"
    });
    try {
      const payload = await requestJSON(request, `${OPEN_FOOD_FACTS_URL}?${params}`, { headers: { "user-agent": "Dayplate/1.0 nutrition lookup" } }, "Open Food Facts search failed.");
      completedSearch = true;
      const batch = asArray(payload?.products);
      products.push(...batch);
      if (batch.some(item => {
        const match = matchScores(query, [item?.product_name, item?.brands].filter(Boolean).join(" "));
        return match.score >= 0.9 && match.literalScore >= 0.7;
      })) break;
    } catch {
      // Continue through the bounded aliases before giving up on this source.
    }
  }
  if (!completedSearch) throw new NutritionSourceError("Open Food Facts search failed.");
  const uniqueProducts = [...new Map(products.map(item => [String(item?.code ?? `${item?.product_name}|${item?.brands}`), item])).values()];
  const ranked = uniqueProducts
    .filter(item => hasCoreNutrients(openFoodFactsNutrients(item?.nutriments)))
    .map(item => {
      const match = matchScores(query, [item.product_name, item.brands].filter(Boolean).join(" "));
      return { item, ...match };
    })
    .sort((left, right) => right.score - left.score);
  const product = ranked[0];
  if (!product || product.score < 0.7) return null;
  const nutrients = openFoodFactsNutrients(product.item.nutriments);
  const productName = displayProductName(product.item.product_name ?? query);
  return {
    name: productName,
    portion: portionLabel(grams),
    sourceName: "Open Food Facts",
    sourceID: String(product.item.code ?? product.item.id ?? query),
    identityMatch: productIdentityMatch(query, productName, ranked.map(candidate => candidate.item?.product_name), [productName, product.item.brands].filter(Boolean).join(" ")),
    referenceServing: referenceServing(product.item.serving_size, product.item.serving_quantity, product.item.serving_quantity_unit),
    nutrients: normalizeNutrients(nutrients, grams / 100)
  };
}

export function manufacturerNutrition(ingredient, result) {
  const reportedNutrients = result?.nutrients ?? result?.nutrientsPerServing;
  if (result?.found === false || !reportedNutrients || positiveNumber(reportedNutrients.calories, 0) <= 0) return null;
  const servingGrams = positiveNumber(result.servingGrams, 0);
  const grams = positiveNumber(ingredient.grams, servingGrams || 100);
  const nutritionBasis = result.nutritionBasis ?? "per_serving";
  const scale = nutritionBasis === "per_100g" ? grams / 100 : servingGrams > 0 ? grams / servingGrams : 1;
  return {
    name: result.name || [ingredient.brand, ingredient.name].filter(Boolean).join(" "),
    portion: researchedPortionLabel(result.servingLabel, grams, servingGrams, nutritionBasis),
    sourceName: result.sourceName || "AI-assisted nutrition research",
    sourceID: result.sourceURL || "ai-web-research",
    identityMatch: {
      score: positiveNumber(result.matchConfidence, 1),
      literalScore: positiveNumber(result.matchConfidence, 1),
      needsConfirmation: Boolean(result.identityNeedsConfirmation),
      candidates: [result.name].filter(Boolean)
    },
    referenceServing: referenceServing(result.servingLabel, servingGrams, null, result.servingCount, result.servingUnit),
    corroboratedBy: asArray(result.evidence)
      .filter(item => item?.sourceURL && item.sourceURL !== result.sourceURL)
      .slice(0, 2)
      .map(item => ({ sourceName: item.sourceName, sourceURL: item.sourceURL })),
    nutrients: normalizeNutrients(reportedNutrients, scale)
  };
}

function curatedProductNutrition(product, grams) {
  const servings = Math.max(1, Math.round(grams / product.servingGrams));
  return {
    name: product.name,
    portion: servings === 1 ? product.servingLabel : String(servings) + " × " + product.servingLabel,
    sourceName: product.sourceName,
    sourceID: product.sourceURL,
    identityMatch: { score: 1, literalScore: 1, needsConfirmation: false, candidates: [product.name] },
    referenceServing: referenceServing(product.servingLabel, product.servingGrams),
    nutrients: normalizeNutrients(product.nutrientsPerServing, servings)
  };
}

export function totals(ingredients) { return ingredients.reduce((sum, item) => add(sum, item.nutrients), zeroNutrients()); }
export function zeroNutrients() { return { calories: 0, carbohydrates: 0, protein: 0, fat: 0, fiber: 0, calcium: 0, iron: 0, magnesium: 0, potassium: 0, sodium: 0, vitaminD: 0 }; }

export function mealClarifications(requestedIngredients, sourcedIngredients, answers = {}) {
  const answered = new Set(Object.keys(answers ?? {}));
  const questions = [];
  for (let index = 0; index < sourcedIngredients.length && questions.length < 2; index += 1) {
    const requested = requestedIngredients[index] ?? {};
    const sourced = sourcedIngredients[index] ?? {};
    const identityID = `food_${index}_identity`;
    if (!answered.has(identityID) && sourced.identityMatch?.needsConfirmation) {
      const candidates = [...new Set(asArray(sourced.identityMatch.candidates).filter(Boolean))].slice(0, 3);
      if (candidates.length) {
        questions.push({
          id: identityID,
          prompt: candidates.length === 1 ? `Did you mean ${candidates[0]}?` : `Which product did you mean by “${requested.name}”?`,
          detail: "The closest nutrition match uses a different product title.",
          options: [
            ...candidates.map((name, optionIndex) => ({ id: `${identityID}_${optionIndex}`, label: candidates.length === 1 ? `Yes — ${name}` : name, value: `The intended product is ${name}.`, action: "answer" })),
            { id: `${identityID}_edit`, label: "None — edit description", value: "", action: "edit" }
          ]
        });
      }
    }

    if (questions.length >= 2) break;
    const amountID = `food_${index}_amount`;
    if (answered.has(amountID)) continue;
    const amountQuestion = servingClarification(amountID, requested, sourced);
    if (amountQuestion) questions.push(amountQuestion);
  }
  return questions.slice(0, 2);
}

function servingClarification(id, requested, sourced) {
  const consumed = sourced.consumedAmount ?? {};
  const reference = sourced.referenceServing;
  const servingGrams = positiveNumber(reference?.grams, 0);
  if (servingGrams <= 0) return null;
  const quantity = positiveNumber(consumed.quantity ?? requested.quantity, 0);
  const totalGrams = positiveNumber(consumed.grams ?? requested.grams, 0);
  const referenceCount = positiveNumber(reference?.count, 0) || 1;
  const gramsPerUnit = servingGrams / referenceCount;
  const explicit = consumed.quantityWasExplicit === true || requested.quantityWasExplicit === true;
  const lowConfidence = (consumed.confidence ?? requested.amountConfidence) === "low";
  const interpretedPerUnit = quantity > 0 && totalGrams > 0 ? totalGrams / quantity : 0;
  const conflictsWithSource = explicit && interpretedPerUnit > 0 && Math.abs(interpretedPerUnit - gramsPerUnit) / gramsPerUnit > 0.2;
  if (!lowConfidence && !conflictsWithSource) return null;

  const unit = singularUnit(requested.quantityUnit || consumed.unit || reference.unit || "item");
  const quantities = conflictsWithSource && quantity > 0 ? [quantity] : [1, 2];
  const options = [];
  if (conflictsWithSource && totalGrams > 0) {
    options.push(servingOption(id, quantity, unit, totalGrams, "interpreted"));
  }
  for (const candidateQuantity of quantities) {
    const candidateGrams = gramsPerUnit * candidateQuantity;
    if (!options.some(option => Math.abs(option.grams - candidateGrams) < 1)) {
      options.push(servingOption(id, candidateQuantity, unit, candidateGrams, String(options.length)));
    }
  }
  if (options.length < 2) return null;
  return {
    id,
    prompt: `How many ${pluralizedUnit(unit, 2)} did you eat?`,
    detail: `The nutrition source lists ${reference.label}${servingGrams ? ` (${Math.round(servingGrams)} g)` : ""}.`,
    options: options.slice(0, 3).map(({ grams, ...option }) => option)
  };
}

function servingOption(id, quantity, unit, grams, suffix) {
  const label = `${formatQuantity(quantity)} ${pluralizedUnit(unit, quantity)} (${Math.round(grams)} g)`;
  return { id: `${id}_${suffix}`, label, value: `Consumed amount: ${label} total.`, action: "answer", grams };
}

function normalizeNutrients(values, scale) {
  return Object.fromEntries(Object.keys(zeroNutrients()).map(key => [key, positiveNumber(values[key], 0) * scale]));
}
function hasCoreNutrients(values) {
  return ["calories", "carbohydrates", "protein", "fat"].every(key => values?.[key] != null && Number.isFinite(Number(values[key])))
    && positiveNumber(values?.calories, 0) > 0;
}
function openFoodFactsNutrients(values = {}) {
  return {
    calories: values["energy-kcal_100g"] ?? values.energy_kcal_100g,
    carbohydrates: values.carbohydrates_100g,
    protein: values.proteins_100g,
    fat: values.fat_100g,
    fiber: values.fiber_100g,
    calcium: values.calcium_100g == null ? undefined : values.calcium_100g * 1000,
    iron: values.iron_100g == null ? undefined : values.iron_100g * 1000,
    potassium: values.potassium_100g == null ? undefined : values.potassium_100g * 1000,
    sodium: values.sodium_100g == null ? undefined : values.sodium_100g * 1000
  };
}
async function trySource(name, failures, lookup) {
  try {
    const result = await lookup();
    if (!result) failures.push(`${name}: no sufficiently close match`);
    return result;
  } catch (error) {
    failures.push(`${name}: ${error instanceof Error ? error.message : "lookup failed"}`);
    return null;
  }
}
async function requestJSON(request, url, options, errorMessage) {
  let lastStatus;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0 && lastStatus) await delay(attempt === 1 ? 250 : 750);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8_000);
    try {
      const response = await request(url, { ...options, signal: controller.signal });
      if (response.ok) return await response.json();
      lastStatus = Number(response.status) || null;
      // Invalid credentials and malformed requests will not recover on retry.
      if (lastStatus === 400 || lastStatus === 401 || lastStatus === 403) break;
    } catch {
      lastStatus = 0;
    } finally {
      clearTimeout(timeout);
    }
  }
  throw new NutritionSourceError(lastStatus ? `${errorMessage} (HTTP ${lastStatus})` : errorMessage);
}
function isTrustworthyNutrition(item, grams, failures) {
  if (!item) return false;
  const issue = nutritionPlausibilityIssue(item.nutrients, grams);
  if (!issue) return true;
  failures.push(`${item.sourceName}: ${issue}`);
  return false;
}
export function nutritionPlausibilityIssue(nutrients, grams) {
  const servingGrams = positiveNumber(grams, 0);
  const calories = positiveNumber(nutrients?.calories, 0);
  const carbohydrates = positiveNumber(nutrients?.carbohydrates, 0);
  const protein = positiveNumber(nutrients?.protein, 0);
  const fat = positiveNumber(nutrients?.fat, 0);
  if (calories <= 0) return "calories are missing";
  if (servingGrams <= 0) return null;

  const macroMass = carbohydrates + protein + fat;
  if (macroMass > servingGrams * 1.35 + 3) {
    return "macronutrients exceed the stated serving mass; the panel may be per 100 g";
  }
  if (calories > servingGrams * 9.2 + 20) {
    return "calories exceed the physical energy limit of the stated serving";
  }
  return null;
}
function add(a, b) { return Object.fromEntries(Object.keys(a).map(key => [key, a[key] + b[key]])); }
function asArray(value) { return Array.isArray(value) ? value : value ? [value] : []; }
function positiveNumber(value, fallback) { const parsed = Number(value); return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback; }
function portionLabel(grams, hint) { return hint ? `${hint} (${Math.round(grams)} g)` : `${Math.round(grams)} g`; }
function researchedPortionLabel(label, grams, servingGrams, nutritionBasis) {
  if (!label) return portionLabel(grams);
  if (nutritionBasis === "per_100g" || servingGrams <= 0) return servingGrams <= 0 ? label : portionLabel(grams, label);
  const servings = grams / servingGrams;
  if (Math.abs(servings - 1) < 0.05) return portionLabel(grams, label);
  if (Math.abs(servings - Math.round(servings)) < 0.05) return `${Math.round(servings)} × ${label} (${Math.round(grams)} g)`;
  return portionLabel(grams);
}
function finalizeSourcedItem(item, ingredient, grams) {
  const quantity = positiveNumber(ingredient.quantity, 0);
  if (ingredient.quantityWasExplicit === true && quantity > 0) {
    const unit = String(ingredient.quantityUnit || "item").trim() || "item";
    item.portion = `${formatQuantity(quantity)} ${pluralizedUnit(unit, quantity)} (${Math.round(grams)} g)`;
  }
  item.consumedAmount = {
    grams,
    quantity: quantity || null,
    unit: ingredient.quantityUnit || null,
    quantityWasExplicit: ingredient.quantityWasExplicit === true,
    confidence: ingredient.amountConfidence || "medium"
  };
  return item;
}
function referenceServing(label, grams, gramUnit, explicitCount, explicitUnit) {
  const servingGrams = positiveNumber(grams, 0);
  const parsed = parseServingCount(label);
  if (!label && servingGrams <= 0 && !explicitCount) return null;
  return {
    label: label || (servingGrams > 0 ? `${Math.round(servingGrams)} ${gramUnit || "g"}` : "1 serving"),
    grams: servingGrams || null,
    count: positiveNumber(explicitCount, 0) || parsed.count || null,
    unit: explicitUnit || parsed.unit || null
  };
}
function parseServingCount(label) {
  const match = String(label ?? "").trim().match(/^(\d+(?:\.\d+)?)\s*(?:x\s*)?([^\d(]+)?/i);
  if (!match) return { count: null, unit: null };
  const unit = String(match[2] ?? "").trim().replace(/\s+$/, "");
  return { count: positiveNumber(match[1], 0) || null, unit: unit || null };
}
function productIdentityMatch(query, selectedName, alternativeNames, selectedSearchText = selectedName) {
  const selected = matchScores(query, selectedSearchText);
  const candidates = dedupeIdentityNames(asArray(alternativeNames).map(displayProductName).filter(Boolean))
    .map(name => ({ name, ...matchScores(query, name) }))
    .filter(candidate => candidate.score >= Math.max(0.65, selected.score - 0.15))
    .sort((left, right) => right.score - left.score)
    .slice(0, 3)
    .map(candidate => candidate.name);
  if (!candidates.includes(displayProductName(selectedName))) candidates.unshift(displayProductName(selectedName));
  return {
    score: selected.score,
    literalScore: selected.literalScore,
    needsConfirmation: selected.literalScore < 0.7 || selected.score < 0.9,
    candidates: candidates.slice(0, 3)
  };
}
function dedupeIdentityNames(names) {
  const unique = new Map();
  for (const name of names) {
    const key = foodSearchTokens(name).filter(token => token !== "frosted").join(" ");
    if (!unique.has(key)) unique.set(key, name);
  }
  return [...unique.values()];
}
function matchScores(query, candidate) {
  const literalQuery = new Set(foodSearchTokens(query));
  const literalCandidate = new Set(foodSearchTokens(candidate));
  const semanticQuery = new Set([...literalQuery].map(semanticFoodToken));
  const semanticCandidate = new Set([...literalCandidate].map(semanticFoodToken));
  const literalScore = tokenCoverage(literalQuery, literalCandidate);
  let semanticScore = tokenCoverage(semanticQuery, semanticCandidate);
  if (literalQuery.has("double") && literalQuery.has("chocolate") && literalCandidate.has("chocotastic")) semanticScore = 1;
  return { score: Math.max(literalScore, semanticScore), literalScore };
}
function tokenCoverage(queryTokens, candidateTokens) {
  if (!queryTokens.size) return 0;
  return [...queryTokens].filter(token => candidateTokens.has(token)).length / queryTokens.size;
}
function semanticFoodToken(token) {
  if (/^choc(?:o|$)/.test(token)) return "chocolate";
  return token;
}
function displayProductName(value) {
  return String(value ?? "").replace(/\s+\d+\s*x\s*$/i, "").trim();
}
function formatQuantity(value) { return Number.isInteger(value) ? String(value) : String(Math.round(value * 100) / 100); }
function singularUnit(unit) { return String(unit).replace(/ies$/i, "y").replace(/s$/i, ""); }
function pluralizedUnit(unit, quantity) {
  if (Math.abs(quantity - 1) < 0.001) return singularUnit(unit);
  const singular = singularUnit(unit);
  return /y$/i.test(singular) ? `${singular.slice(0, -1)}ies` : `${singular}s`;
}
function ingredientPortionHint(food) { return food?.householdServingFullText || null; }
function normalize(value) {
  return String(value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}
function foodSearchTokens(value) {
  return normalize(value).split(" ").filter(token => token.length > 1);
}
function openFoodFactsSearchQueries(query) {
  const tokens = foodSearchTokens(query);
  const variants = [tokens.join(" ")];
  if (tokens.includes("double") && tokens.includes("chocolate")) {
    variants.push(tokens.filter(token => token !== "double" && token !== "chocolate").concat("chocotastic").join(" "));
  }
  const relaxedTerms = new Set(["chocolate", "frosted", "flavor", "flavoured", "flavored"]);
  if (tokens.includes("double") && tokens.includes("chocolate")) relaxedTerms.add("double");
  const relaxed = tokens.filter(token => !relaxedTerms.has(token));
  if (relaxed.length >= 2) variants.push(relaxed.join(" "));
  return [...new Set(variants.filter(Boolean))].slice(0, 3);
}

function usdaSearchQueries(query) {
  const tokens = foodSearchTokens(query);
  const variants = [tokens.join(" ")];
  const relaxedTerms = new Set(["frosted", "flavor", "flavoured", "flavored"]);
  if (tokens.includes("double") && tokens.includes("chocolate")) relaxedTerms.add("double");
  const relaxed = tokens.filter(token => !relaxedTerms.has(token));
  if (relaxed.length >= 2) variants.push(relaxed.join(" "));
  return [...new Set(variants.filter(Boolean))].slice(0, 2);
}

function bestUsdaCandidates(foods, query, dataType) {
  const permittedFoods = dataType
    ? foods.filter(food => String(food?.dataType ?? "").toLowerCase() === dataType.toLowerCase())
    : foods.filter(food => String(food?.dataType ?? "").toLowerCase() !== "branded");
  const ranked = (permittedFoods.length ? permittedFoods : foods)
    .map(food => {
      const candidateText = [food?.description, food?.brandOwner, food?.brandName].filter(Boolean).join(" ");
      return { food, ...matchScores(query, candidateText) };
    })
    .sort((left, right) => right.score - left.score || right.literalScore - left.literalScore || Number(left.food?.fdcId ?? 0) - Number(right.food?.fdcId ?? 0));

  // A loose branded match can have an unrelated nutrient panel. Let the
  // official-product fallback handle it instead of returning a plausible but
  // wrong item such as a different sandwich from the same chain.
  return dataType ? ranked.filter(candidate => candidate.score >= 0.7) : ranked;
}

function delay(milliseconds) { return new Promise(resolve => setTimeout(resolve, milliseconds)); }
