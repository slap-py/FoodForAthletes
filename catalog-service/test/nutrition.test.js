import test from "node:test";
import assert from "node:assert/strict";
import { sourceIngredient } from "../src/nutrition.js";

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

function response(value) { return { ok: true, json: async () => value }; }
