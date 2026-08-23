import test from "node:test";
import assert from "node:assert/strict";
import { manufacturerNutrition, mealClarifications, nutritionPlausibilityIssue, sourceIngredient } from "../src/nutrition.js";

test("generic ingredients search the full USDA corpus and scale detail nutrients", async () => {
  const calls = [];
  const request = async url => {
    calls.push(url);
    if (url.includes("foods/search")) return response({ foods: [{ fdcId: 123, description: "Chicken breast" }] });
    return response({ description: "Chicken breast", foodNutrients: [
      { nutrient: { name: "Energy" }, amount: 165 },
      { nutrient: { name: "Carbohydrate, by difference" }, amount: 0 },
      { nutrient: { name: "Protein" }, amount: 31 },
      { nutrient: { name: "Total lipid (fat)" }, amount: 3.6 }
    ] });
  };
  const item = await sourceIngredient({ name: "chicken breast", brand: null, kind: "generic", grams: 150 }, { foodDataCentralKey: "key" }, async () => null, request);
  assert.equal(calls.length, 2);
  assert.doesNotMatch(calls[0], /dataType=/);
  assert.equal(item.sourceName, "USDA FoodData Central");
  assert.equal(item.nutrients.calories, 247.5);
  assert.equal(item.nutrients.protein, 46.5);
});

test("branded ingredients try USDA Branded before other sources", async () => {
  const calls = [];
  const request = async url => {
    calls.push(url);
    if (url.includes("foods/search")) return response({ foods: [{ fdcId: 456, description: "Example snack" }] });
    return response({ description: "Example snack", servingSize: 50, labelNutrients: { calories: { value: 200 }, carbohydrates: { value: 20 }, protein: { value: 4 }, fat: { value: 10 }, fiber: { value: 6 } } });
  };
  const item = await sourceIngredient({ name: "snack", brand: "Example", kind: "branded", grams: 25 }, { foodDataCentralKey: "key" }, async () => { throw new Error("manufacturer fallback should not run"); }, request);
  assert.match(calls[0], /dataType=Branded/);
    assert.equal(item.sourceName, "USDA FoodData Central — Branded");
    assert.equal(item.nutrients.calories, 100);
    assert.equal(item.nutrients.carbohydrates, 10, "USDA Total Carbohydrate must not add fiber or sugars again");
    assert.equal(item.nutrients.fiber, 3);
});

test("manufacturer serving facts keep an exact menu product whole", () => {
  const product = manufacturerNutrition(
    { name: "Double-Smoked Bacon, Cheddar & Egg Sandwich", brand: "Starbucks", kind: "branded", grams: 180 },
    {
      name: "Double-Smoked Bacon, Cheddar & Egg Sandwich",
      sourceURL: "https://www.starbucks.com/menu/product/example",
      sourceName: "Starbucks nutrition",
      servingLabel: "1 sandwich",
      servingGrams: null,
      nutrientsPerServing: { calories: 500, carbohydrates: 42, protein: 24, fat: 28, fiber: 2, calcium: 150, iron: 2.5, magnesium: 20, potassium: 300, sodium: 1180, vitaminD: 1 }
    }
  );

  assert.equal(product.name, "Double-Smoked Bacon, Cheddar & Egg Sandwich");
  assert.equal(product.portion, "1 sandwich");
  assert.equal(product.sourceName, "Starbucks nutrition");
  assert.equal(product.nutrients.calories, 500);
  assert.equal(product.nutrients.carbohydrates, 42);
  assert.equal(product.nutrients.protein, 24);
});

test("weak branded database matches fall through to an exact manufacturer product", async () => {
  const request = async url => {
    if (url.includes("foods/search")) return response({ foods: [] });
    return response({ products: [{
      product_name: "Holiday jelly candy",
      brands: "Starbucks",
      code: "wrong-product",
      nutriments: { "energy-kcal_100g": 400 }
    }] });
  };
  const item = await sourceIngredient(
    { name: "Double-Smoked Bacon, Cheddar & Egg Sandwich", brand: "Starbucks", kind: "branded", grams: 180 },
    { foodDataCentralKey: "key" },
    async ingredient => manufacturerNutrition(ingredient, {
      name: "Double-Smoked Bacon, Cheddar & Egg Sandwich",
      sourceURL: "https://www.starbucks.com/menu/product/example",
      sourceName: "Starbucks nutrition",
      servingLabel: "1 sandwich",
      servingGrams: null,
      nutrientsPerServing: { calories: 500, carbohydrates: 42, protein: 24, fat: 28, fiber: 2, calcium: 150, iron: 2.5, magnesium: 20, potassium: 300, sodium: 1180, vitaminD: 1 }
    }),
    request
  );

  assert.equal(item.name, "Double-Smoked Bacon, Cheddar & Egg Sandwich");
  assert.equal(item.sourceName, "Starbucks nutrition");
});

test("curated menu products are used in the final research tier after USDA and Open Food Facts", async () => {
  const calls = [];
  const item = await sourceIngredient(
    { name: "Double-Smoked Bacon, Cheddar & Egg Sandwich", brand: "Starbucks", kind: "branded", grams: 148 },
    { foodDataCentralKey: "key" },
    async () => { throw new Error("curated product should not need fallback"); },
    async url => {
      calls.push(url);
      return url.includes("foods/search") ? response({ foods: [] }) : response({ products: [] });
    }
  );

  assert.equal(calls.length, 2);
  assert.match(calls[0], /api\.nal\.usda\.gov/);
  assert.match(calls[1], /openfoodfacts\.org/);
  assert.equal(item.name, "Double-Smoked Bacon, Cheddar & Egg Sandwich");
  assert.equal(item.portion, "1 sandwich");
  assert.equal(item.nutrients.calories, 500);
  assert.equal(item.nutrients.carbohydrates, 43);
  assert.equal(item.nutrients.protein, 21);
  assert.equal(item.nutrients.fat, 27);
});

test("a USDA outage falls through to Open Food Facts before AI research", async () => {
  const calls = [];
  const item = await sourceIngredient(
    { name: "Chocolate Bite", brand: "Fallback Foods", kind: "branded", grams: 50 },
    { foodDataCentralKey: "key" },
    async () => { throw new Error("AI research should not run when Open Food Facts succeeds"); },
    async url => {
      calls.push(url);
      if (url.includes("api.nal.usda.gov")) return { ok: false };
      return response({ products: [{
        product_name: "Chocolate Bite",
        brands: "Fallback Foods",
        code: "fallback-chocolate-bite",
        nutriments: { "energy-kcal_100g": 400, carbohydrates_100g: 60, proteins_100g: 5, fat_100g: 15, fiber_100g: 4 }
      }] });
    }
  );

  assert.equal(calls.length, 4);
  assert.match(calls[0], /api\.nal\.usda\.gov/);
  assert.match(calls[1], /api\.nal\.usda\.gov/);
  assert.match(calls[2], /api\.nal\.usda\.gov/);
  assert.match(calls[3], /openfoodfacts\.org/);
  assert.equal(item.sourceName, "Open Food Facts");
  assert.equal(item.nutrients.calories, 200);
  assert.equal(item.nutrients.carbohydrates, 30);
});

test("generic foods also fall through USDA and Open Food Facts to AI research", async () => {
  const calls = [];
  let researched = false;
  const item = await sourceIngredient(
    { name: "test orchard fruit", brand: null, kind: "generic", grams: 120 },
    { foodDataCentralKey: "key" },
    async ingredient => {
      researched = true;
      return manufacturerNutrition(ingredient, {
        name: "Test orchard fruit",
        sourceURL: "https://example.test/orchard-fruit",
        sourceName: "University food composition table",
        servingLabel: "100 g",
        servingGrams: 100,
        nutritionBasis: "per_100g",
        nutrients: { calories: 50, carbohydrates: 12, protein: 1, fat: 0.2, fiber: 2, calcium: 5, iron: 0.2, magnesium: 4, potassium: 100, sodium: 1, vitaminD: 0 },
        evidence: []
      });
    },
    async url => {
      calls.push(url);
      return url.includes("foods/search") ? response({ foods: [] }) : response({ products: [] });
    }
  );

  assert.equal(researched, true);
  assert.equal(calls.length, 2);
  assert.equal(item.sourceName, "University food composition table");
  assert.equal(item.nutrients.calories, 60);
});

test("USDA tries another ranked record when the first detail record is unavailable", async () => {
  const detailCalls = [];
  const item = await sourceIngredient(
    { name: "reliable test lentils", brand: null, kind: "generic", grams: 100 },
    { foodDataCentralKey: "key" },
    async () => { throw new Error("USDA should recover before fallback"); },
    async url => {
      if (url.includes("foods/search")) return response({ foods: [
        { fdcId: 101, description: "Reliable test lentils" },
        { fdcId: 102, description: "Reliable test lentils cooked" }
      ] });
      detailCalls.push(url);
      if (url.includes("/101?")) return { ok: false, status: 503 };
      return response({ description: "Reliable test lentils cooked", foodNutrients: [
        { nutrient: { name: "Energy" }, amount: 116 },
        { nutrient: { name: "Carbohydrate, by difference" }, amount: 20 },
        { nutrient: { name: "Protein" }, amount: 9 },
        { nutrient: { name: "Total lipid (fat)" }, amount: 0.4 }
      ] });
    }
  );

  assert.equal(detailCalls.filter(url => url.includes("/101?")).length, 3);
  assert.equal(detailCalls.filter(url => url.includes("/102?")).length, 1);
  assert.equal(item.sourceID, "102");
  assert.equal(item.nutrients.calories, 116);
});

test("normalized simultaneous ingredient requests share one deterministic lookup", async () => {
  let calls = 0;
  const request = async url => {
    calls += 1;
    if (url.includes("foods/search")) return response({ foods: [{ fdcId: 987, description: "Concurrent cache test food" }] });
    return response({ description: "Concurrent cache test food", foodNutrients: [
      { nutrient: { name: "Energy" }, amount: 100 },
      { nutrient: { name: "Carbohydrate, by difference" }, amount: 20 },
      { nutrient: { name: "Protein" }, amount: 2 },
      { nutrient: { name: "Total lipid (fat)" }, amount: 1 }
    ] });
  };
  const credentials = { foodDataCentralKey: "key" };
  const [first, second] = await Promise.all([
    sourceIngredient({ name: "Concurrent Cache Test Food", brand: null, kind: "generic", grams: 100 }, credentials, async () => null, request),
    sourceIngredient({ name: "  concurrent cache test food ", brand: null, kind: "generic", grams: 100 }, credentials, async () => null, request)
  ]);

  assert.equal(calls, 2);
  assert.equal(first.sourceID, second.sourceID);
  assert.deepEqual(first.nutrients, second.nutrients);
});

test("per-100-g panels are rescaled instead of being treated as a smaller serving", async () => {
  const ingredient = { name: "Frosted Chocotastic Pop-Tart", brand: "Kellogg's", kind: "branded", grams: 48 };
  const item = manufacturerNutrition(ingredient, {
    found: true,
    name: "Frosted Chocotastic Pop-Tart",
    sourceURL: "https://example.test/pop-tart",
    sourceName: "Product nutrition page",
    servingLabel: "1 pastry",
    servingGrams: 48,
    nutritionBasis: "per_100g",
    nutrients: { calories: 378, carbohydrates: 70, protein: 4, fat: 9.2, fiber: 2, calcium: 0, iron: 0, magnesium: 0, potassium: 0, sodium: 500, vitaminD: 0 },
    evidence: [{ sourceName: "Second label database", sourceURL: "https://example.test/corroboration" }]
  });

  assert.equal(item.nutrients.calories, 181.44);
  assert.equal(item.nutrients.carbohydrates, 33.6);
  assert.equal(item.nutrients.fat, 4.4159999999999995);
  assert.deepEqual(item.corroboratedBy, [{ sourceName: "Second label database", sourceURL: "https://example.test/corroboration" }]);
  assert.equal(nutritionPlausibilityIssue(item.nutrients, 48), null);
  assert.match(nutritionPlausibilityIssue({ calories: 378, carbohydrates: 70, protein: 4, fat: 9.2 }, 48), /per 100 g/);
});

test("approximate chocolate product titles match Chocotastic and request identity confirmation", async () => {
  const requested = {
    name: "Double Chocolate Pop-Tarts",
    brand: "Kellogg's",
    kind: "branded",
    grams: 96,
    quantity: 2,
    quantityUnit: "pastry",
    quantityWasExplicit: true,
    amountConfidence: "high"
  };
  const item = await sourceIngredient(
    requested,
    {},
    async () => { throw new Error("AI research should not run for a strong fuzzy OFF match"); },
    async () => response({ products: [{
      product_name: "Pop Tarts Frosted Chocotastic 8 x",
      brands: "Kellogg's",
      code: "chocotastic",
      serving_size: "1 Pop-Tart (48 g)",
      serving_quantity: 48,
      serving_quantity_unit: "g",
      nutriments: { "energy-kcal_100g": 396, carbohydrates_100g: 68, proteins_100g: 5, fat_100g: 11 }
    }] })
  );

  assert.equal(item.name, "Pop Tarts Frosted Chocotastic");
  assert.equal(item.portion, "2 pastries (96 g)");
  assert.equal(item.identityMatch.needsConfirmation, true);
  assert.equal(item.referenceServing.grams, 48);
  const questions = mealClarifications([requested], [item]);
  assert.equal(questions.length, 1, "an explicit 2 × 48 g amount should not need another serving question");
  assert.match(questions[0].prompt, /Chocotastic/);
});

test("serving clarification is asked when interpreted per-item weight conflicts with the source", () => {
  const requested = { name: "Chocolate pastries", grams: 48, quantity: 2, quantityUnit: "pastry", quantityWasExplicit: true, amountConfidence: "high" };
  const sourced = {
    name: "Chocolate pastries",
    identityMatch: { needsConfirmation: false },
    consumedAmount: { grams: 48, quantity: 2, unit: "pastry", quantityWasExplicit: true, confidence: "high" },
    referenceServing: { label: "1 pastry (48 g)", grams: 48, count: 1, unit: "pastry" }
  };

  const questions = mealClarifications([requested], [sourced]);
  assert.equal(questions.length, 1);
  assert.match(questions[0].prompt, /How many pastries/);
  assert.deepEqual(questions[0].options.map(option => option.label), ["2 pastries (48 g)", "2 pastries (96 g)"]);
});

function response(value) { return { ok: true, json: async () => value }; }
