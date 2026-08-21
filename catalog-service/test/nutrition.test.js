import test from "node:test";
import assert from "node:assert/strict";
import { manufacturerNutrition, sourceIngredient } from "../src/nutrition.js";

test("generic ingredients search the full USDA corpus and scale detail nutrients", async () => {
  const calls = [];
  const request = async url => {
    calls.push(url);
    if (url.includes("foods/search")) return response({ foods: [{ fdcId: 123, description: "Chicken breast" }] });
    return response({ description: "Chicken breast", foodNutrients: [
      { nutrient: { name: "Energy" }, amount: 165 },
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

test("curated menu products bypass ambiguous component searches", async () => {
  const item = await sourceIngredient(
    { name: "Double-Smoked Bacon, Cheddar & Egg Sandwich", brand: "Starbucks", kind: "branded", grams: 148 },
    { foodDataCentralKey: "key" },
    async () => { throw new Error("curated product should not need fallback"); },
    async () => { throw new Error("curated product should not search a generic component"); }
  );

  assert.equal(item.name, "Double-Smoked Bacon, Cheddar & Egg Sandwich");
  assert.equal(item.portion, "1 sandwich");
  assert.equal(item.nutrients.calories, 500);
  assert.equal(item.nutrients.carbohydrates, 43);
  assert.equal(item.nutrients.protein, 21);
  assert.equal(item.nutrients.fat, 27);
});

function response(value) { return { ok: true, json: async () => value }; }
