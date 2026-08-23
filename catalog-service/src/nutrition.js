import { curatedMenuProduct } from "./menuProducts.js";

const USDA_API_URL = "https://api.nal.usda.gov/fdc/v1";
const OPEN_FOOD_FACTS_URL = "https://world.openfoodfacts.org/cgi/search.pl";
const ingredientCache = new Map();
const INGREDIENT_CACHE_TTL_MS = 30 * 60 * 1000;
const INGREDIENT_CACHE_MAX_ENTRIES = 256;

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
    Math.round(positiveNumber(ingredient.grams, 100)),
    positiveNumber(ingredient.quantity, 0),
    normalize(ingredient.quantityUnit),
    ingredient.quantityWasExplicit === true,
    ingredient.amountConfidence
  ]);
  sweepCache(ingredientCache, INGREDIENT_CACHE_MAX_ENTRIES);
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
  const curated = ingredient.kind === "branded" ? curatedMenuProduct(ingredient) : null;

  const usda = await trySource("USDA", failures, () => usdaIngredient(
    query,
    grams,
    credentials.foodDataCentralKey,
    request,
    ingredient.kind === "branded" ? "Branded" : undefined
  ));
  if (isTrustworthyNutrition(usda, grams, failures)) {
    const corroborated = corroborateKnownProduct(usda, curated, grams, failures);
    if (corroborated) return finalizeSourcedItem(corroborated, ingredient, grams);
  }

  const off = await trySource("Open Food Facts", failures, () => openFoodFactsIngredient(query, grams, request, ingredient.kind === "branded"));
  if (isTrustworthyNutrition(off, grams, failures)) {
    const corroborated = corroborateKnownProduct(off, curated, grams, failures);
    if (corroborated) return finalizeSourcedItem(corroborated, ingredient, grams);
  }

  if (curated) {
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
  const params = new URLSearchParams({ query: normalize(query), pageSize: "12", api_key: apiKey });
  if (dataType) params.set("dataType", dataType);
  const search = await requestJSON(request, `${USDA_API_URL}/foods/search?${params}`, undefined, "USDA search failed.");
  const foods = asArray(search?.foods);
  const candidate = bestUsdaCandidates(foods, query, dataType)[0]?.food;
  if (!candidate?.fdcId) return null;

  const food = await requestJSON(request, `${USDA_API_URL}/food/${candidate.fdcId}?api_key=${encodeURIComponent(apiKey)}`, undefined, "USDA food detail lookup failed.");
  const perPortion = usdaNutrients(food, grams);
  if (!perPortion) return null;
  const candidateName = food.description ?? candidate.description ?? query;
  return {
    name: candidateName,
    portion: portionLabel(grams, ingredientPortionHint(food)),
    sourceName: dataType ? "USDA FoodData Central — Branded" : "USDA FoodData Central",
    sourceTier: "usda",
    sourceID: String(candidate.fdcId),
    identityMatch: productIdentityMatch(query, candidateName, foods.map(item => item?.description), [candidateName, food?.brandOwner, food?.brandName].filter(Boolean).join(" "), Boolean(dataType)),
    referenceServing: referenceServing(ingredientPortionHint(food), servingSizeInGrams(food?.servingSize, food?.servingSizeUnit), "g"),
    nutrients: perPortion
  };
}

function usdaNutrients(food, grams) {
  const label = food?.labelNutrients;
  const servingGrams = servingSizeInGrams(food?.servingSize, food?.servingSizeUnit);
  if (label && servingGrams > 0) {
    const scale = grams / servingGrams;
    const values = {
      calories: label.calories?.value,
      carbohydrates: label.carbohydrates?.value,
      protein: label.protein?.value,
      fat: label.fat?.value,
      fiber: label.fiber?.value,
      calcium: label.calcium?.value,
      iron: label.iron?.value,
      magnesium: label.magnesium?.value,
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

async function openFoodFactsIngredient(query, grams, request, allowFuzzy) {
  const params = new URLSearchParams({
    search_terms: normalize(query),
    search_simple: "1",
    action: "process",
    json: "1",
    page_size: "12",
    fields: "code,product_name,brands,nutriments,serving_size,serving_quantity,serving_quantity_unit"
  });
  const payload = await requestJSON(request, `${OPEN_FOOD_FACTS_URL}?${params}`, { headers: { "user-agent": "Dayplate/1.0 nutrition lookup" } }, "Open Food Facts search failed.");
  const products = asArray(payload?.products);
  const uniqueProducts = [...new Map(products.map(item => [String(item?.code ?? `${item?.product_name}|${item?.brands}`), item])).values()];
  const ranked = uniqueProducts
    .filter(item => hasCoreNutrients(openFoodFactsNutrients(item?.nutriments)))
    .map(item => {
      const match = matchScores(query, [item.product_name, item.brands].filter(Boolean).join(" "), allowFuzzy);
      return { item, ...match };
    })
    .sort((left, right) => right.score - left.score);
  const product = ranked[0];
  if (!product || product.score < (allowFuzzy ? 0.7 : 0.9)) return null;
  const nutrients = openFoodFactsNutrients(product.item.nutriments);
  const productName = displayProductName(product.item.product_name ?? query);
  return {
    name: productName,
    portion: portionLabel(grams),
    sourceName: "Open Food Facts",
    sourceTier: "open_food_facts",
    sourceID: String(product.item.code ?? product.item.id ?? query),
    identityMatch: productIdentityMatch(query, productName, ranked.map(candidate => candidate.item?.product_name), [productName, product.item.brands].filter(Boolean).join(" "), allowFuzzy),
    referenceServing: referenceServing(product.item.serving_size, product.item.serving_quantity, product.item.serving_quantity_unit),
    nutrients: normalizeNutrients(nutrients, grams / 100)
  };
}

export function manufacturerNutrition(ingredient, result) {
  const reportedNutrients = result?.nutrients ?? result?.nutrientsPerServing;
  if (result?.found === false || !hasCoreNutrients(reportedNutrients)) return null;
  const servingGrams = positiveNumber(result.servingGrams, 0);
  const grams = positiveNumber(ingredient.grams, servingGrams || 100);
  const nutritionBasis = result.nutritionBasis ?? "per_serving";
  const scale = nutritionBasis === "per_100g" ? grams / 100 : servingGrams > 0 ? grams / servingGrams : 1;
  return {
    name: result.name || [ingredient.brand, ingredient.name].filter(Boolean).join(" "),
    portion: researchedPortionLabel(result.servingLabel, grams, servingGrams, nutritionBasis),
    sourceName: result.sourceName || "AI-assisted nutrition research",
    sourceTier: "web",
    sourceID: result.sourceURL || "ai-web-research",
    identityMatch: {
      score: nonnegativeNumber(result.matchConfidence, 1),
      literalScore: nonnegativeNumber(result.matchConfidence, 1),
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
  const servings = grams / product.servingGrams;
  const consumedCount = servings * (product.servingCount ?? 1);
  const unit = /pastr/i.test(product.servingLabel) ? "pastry" : null;
  return {
    name: product.name,
    portion: servings === 1
      ? product.servingLabel
      : unit ? `${formatQuantity(consumedCount)} ${pluralizedUnit(unit, consumedCount)}` : portionLabel(grams),
    sourceName: product.sourceName,
    sourceTier: "brand",
    sourceID: product.sourceURL,
    identityMatch: { score: 1, literalScore: 1, needsConfirmation: false, candidates: [product.name] },
    referenceServing: referenceServing(product.servingLabel, product.servingGrams),
    nutrients: normalizeNutrients(product.nutrientsPerServing, servings)
  };
}

function corroborateKnownProduct(item, product, grams, failures) {
  if (!product) return item;
  const official = curatedProductNutrition(product, grams);
  const materiallyDifferent = ["calories", "carbohydrates", "protein", "fat"].some(key => {
    const left = nonnegativeNumber(item.nutrients?.[key], 0);
    const right = nonnegativeNumber(official.nutrients?.[key], 0);
    return Math.abs(left - right) / Math.max(left, right, 1) > 0.25;
  });
  if (materiallyDifferent) {
    failures.push(`${item.sourceName}: core nutrients conflict with ${product.sourceName}`);
    return null;
  }
  return {
    ...item,
    identityMatch: official.identityMatch,
    referenceServing: official.referenceServing,
    corroboratedBy: [{ sourceName: product.sourceName, sourceURL: product.sourceURL }]
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
  return Object.fromEntries(Object.keys(zeroNutrients()).map(key => [key, nonnegativeNumber(values[key], 0) * scale]));
}
function hasCoreNutrients(values) {
  return ["calories", "carbohydrates", "protein", "fat"].every(key => {
    const value = Number(values?.[key]);
    return values?.[key] != null && Number.isFinite(value) && value >= 0;
  });
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
    magnesium: values.magnesium_100g == null ? undefined : values.magnesium_100g * 1000,
    potassium: values.potassium_100g == null ? undefined : values.potassium_100g * 1000,
    sodium: values.sodium_100g == null ? undefined : values.sodium_100g * 1000,
    vitaminD: (values["vitamin-d_100g"] ?? values.vitamin_d_100g) == null
      ? undefined
      : (values["vitamin-d_100g"] ?? values.vitamin_d_100g) * 1_000_000
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
  const maximumAttempts = 2;
  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    if (attempt > 0 && lastStatus !== undefined) await delay(750);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 6_000);
    try {
      const response = await request(url, { ...options, signal: controller.signal });
      if (response.ok) return await response.json();
      lastStatus = Number(response.status) || 0;
      console.warn(`${errorMessage} HTTP ${lastStatus}; attempt ${attempt + 1}/${maximumAttempts}`);
      // Retrying rate limits adds load. Let the next nutrition tier take over.
      if (lastStatus === 400 || lastStatus === 401 || lastStatus === 403 || lastStatus === 429) break;
    } catch (error) {
      lastStatus = 0;
      console.warn(`${errorMessage} network error; attempt ${attempt + 1}/${maximumAttempts}`, error instanceof Error ? error.message : "unknown error");
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
  const calories = nonnegativeNumber(nutrients?.calories, NaN);
  const carbohydrates = nonnegativeNumber(nutrients?.carbohydrates, NaN);
  const protein = nonnegativeNumber(nutrients?.protein, NaN);
  const fat = nonnegativeNumber(nutrients?.fat, NaN);
  if (![calories, carbohydrates, protein, fat].every(Number.isFinite)) return "core nutrients are missing";
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
function positiveNumber(value, fallback) { const parsed = Number(value); return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback; }
function nonnegativeNumber(value, fallback) { const parsed = Number(value); return value != null && Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback; }
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
  const countableExplicitUnit = countableServingUnit(explicitUnit);
  const explicitUnitWasUncountable = String(explicitUnit ?? "").trim() && !countableExplicitUnit;
  if (!label && servingGrams <= 0 && !explicitCount) return null;
  return {
    label: label || (servingGrams > 0 ? `${Math.round(servingGrams)} ${gramUnit || "g"}` : "1 serving"),
    grams: servingGrams || null,
    count: explicitUnitWasUncountable ? parsed.count || null : positiveNumber(explicitCount, 0) || parsed.count || null,
    unit: countableExplicitUnit || parsed.unit || null
  };
}
function parseServingCount(label) {
  const match = String(label ?? "").trim().match(/^(\d+(?:\.\d+)?)\s*(?:x\s*)?([^\d(]+)?/i);
  if (!match) return { count: null, unit: null };
  const rawUnit = String(match[2] ?? "").trim().replace(/\s+$/, "");
  const unit = countableServingUnit(rawUnit);
  if (rawUnit && !unit) return { count: null, unit: null };
  return { count: positiveNumber(match[1], 0) || null, unit: unit || null };
}
function productIdentityMatch(query, selectedName, alternativeNames, selectedSearchText = selectedName, allowFuzzy = false) {
  const selected = matchScores(query, selectedSearchText, allowFuzzy);
  const candidates = dedupeIdentityNames(asArray(alternativeNames).map(displayProductName).filter(Boolean))
    .map(name => ({ name, ...matchScores(query, name, allowFuzzy) }))
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
    const key = foodSearchTokens(name).join(" ");
    if (!unique.has(key)) unique.set(key, name);
  }
  return [...unique.values()];
}
function matchScores(query, candidate, allowFuzzy = false) {
  const literalQuery = new Set(foodSearchTokens(query));
  const literalCandidate = new Set(foodSearchTokens(candidate));
  const literalScore = tokenCoverage(literalQuery, literalCandidate);
  const fuzzyScore = allowFuzzy ? fuzzyTokenCoverage(literalQuery, literalCandidate) : literalScore;
  return { score: Math.max(literalScore, fuzzyScore), literalScore };
}
function tokenCoverage(queryTokens, candidateTokens) {
  if (!queryTokens.size) return 0;
  return [...queryTokens].filter(token => candidateTokens.has(token)).length / queryTokens.size;
}
function fuzzyTokenCoverage(queryTokens, candidateTokens) {
  if (!queryTokens.size) return 0;
  return [...queryTokens].filter(queryToken => [...candidateTokens].some(candidateToken => {
    if (queryToken === candidateToken) return true;
    if (queryToken.length < 7 || candidateToken.length < 7) return false;
    let commonPrefix = 0;
    while (commonPrefix < Math.min(queryToken.length, candidateToken.length)
      && queryToken[commonPrefix] === candidateToken[commonPrefix]) commonPrefix += 1;
    return commonPrefix >= 4 && commonPrefix / Math.min(queryToken.length, candidateToken.length) >= 0.4;
  })).length / queryTokens.size;
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
function bestUsdaCandidates(foods, query, dataType) {
  const permittedFoods = dataType
    ? foods.filter(food => String(food?.dataType ?? "").toLowerCase() === dataType.toLowerCase())
    : foods.filter(food => String(food?.dataType ?? "").toLowerCase() !== "branded");
  const ranked = (permittedFoods.length ? permittedFoods : foods)
    .map(food => {
      const candidateText = [food?.description, food?.brandOwner, food?.brandName].filter(Boolean).join(" ");
      return { food, ...matchScores(query, candidateText, Boolean(dataType)) };
    })
    .sort((left, right) => right.score - left.score || right.literalScore - left.literalScore || Number(left.food?.fdcId ?? 0) - Number(right.food?.fdcId ?? 0));

  // A loose branded match can have an unrelated nutrient panel. Let the
  // official-product fallback handle it instead of returning a plausible but
  // wrong item such as a different sandwich from the same chain.
  return dataType ? ranked.filter(candidate => candidate.score >= 0.7) : ranked;
}

function delay(milliseconds) { return new Promise(resolve => setTimeout(resolve, milliseconds)); }

function servingSizeInGrams(size, unit) {
  const amount = positiveNumber(size, 0);
  const normalizedUnit = normalize(unit);
  if (!amount) return 0;
  if (!normalizedUnit || ["g", "gram", "grams"].includes(normalizedUnit)) return amount;
  if (["oz", "ounce", "ounces"].includes(normalizedUnit)) return amount * 28.3495;
  if (["kg", "kilogram", "kilograms"].includes(normalizedUnit)) return amount * 1000;
  if (["mg", "milligram", "milligrams"].includes(normalizedUnit)) return amount / 1000;
  return 0;
}

function countableServingUnit(unit) {
  const value = String(unit ?? "").trim();
  if (!value) return null;
  const normalizedUnit = normalize(value);
  const uncountable = new Set([
    "g", "gram", "grams", "mg", "milligram", "milligrams", "kg", "kilogram", "kilograms",
    "ml", "milliliter", "milliliters", "millilitre", "millilitres", "l", "liter", "liters", "litre", "litres",
    "oz", "ounce", "ounces", "fl oz", "fluid ounce", "fluid ounces", "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons"
  ]);
  return uncountable.has(normalizedUnit) ? null : value;
}

function sweepCache(cache, maximumEntries) {
  const now = Date.now();
  for (const [key, entry] of cache) {
    if (entry?.expiresAt <= now) cache.delete(key);
  }
  while (cache.size >= maximumEntries) cache.delete(cache.keys().next().value);
}
