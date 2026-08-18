import test from "node:test";
import assert from "node:assert/strict";
import { fatSecretFood, searchFatSecretFoods, usdaFood } from "../src/providers.js";

test("FatSecret v5 search returns the API's full serving list directly", async () => {
  const calls = [];
  const request = async (url, options = {}) => {
    calls.push({ url, options });
    if (url.includes("oauth.fatsecret.com")) return jsonResponse({ access_token: "token", expires_in: 3600 });
    return jsonResponse({ foods_search: { results: { food: {
      food_id: "123", food_name: "Uncrustables", brand_name: "Smucker's",
      servings: { serving: [
        { serving_id: "1", serving_description: "100 g", calories: "400" },
        { serving_id: "2", serving_description: "1 sandwich", calories: "230", is_default: "1" }
      ] }
    } } } });
  };

  const foods = await searchFatSecretFoods("uncrustables", { fatSecretClientID: "id", fatSecretClientSecret: "secret" }, request);
  assert.equal(calls.length, 2);
  assert.match(calls[0].options.body, /scope=premier/);
  assert.match(calls[1].url, /\/foods\/search\/v5\?/);
  assert.equal(foods[0].servings[0].label, "1 sandwich");
  assert.deepEqual(foods[0].servings.map(serving => serving.label), ["1 sandwich", "100 g"]);
});

test("FatSecret food details preserve the API's editable standard servings", () => {
  const food = fatSecretFood({
    food_id: "41963",
    food_name: "Cheeseburger",
    brand_name: "McDonald's",
    servings: { serving: [
      { serving_id: "10", serving_description: "100 g", metric_serving_amount: "100", metric_serving_unit: "g", calories: "250", carbohydrate: "26", protein: "12", fat: "10" },
      { serving_id: "11", serving_description: "1 sandwich", metric_serving_amount: "120", metric_serving_unit: "g", calories: "300", carbohydrate: "32", protein: "15", fat: "13", fiber: "2", calcium: "20", iron: "1.5", sodium: "640", vitamin_d: "2" }
    ] }
  }, {
    food_description: "Per 1 sandwich - Calories: 300kcal | Fat: 13.00g | Carbs: 32.00g | Protein: 15.00g"
  });
  assert.equal(food.id, "fatsecret:41963");
  assert.deepEqual(food.servings.map(serving => serving.label), ["1 sandwich", "100 g"]);
  assert.deepEqual(food.servings[0].nutrients, { calories: 300, carbohydrates: 32, protein: 15, fat: 13, fiber: 2, calcium: 20, iron: 1.5, magnesium: 0, potassium: 0, sodium: 640, vitaminD: 2 });
  assert.equal(food.provenance[0].source, "FatSecret");
});

test("FatSecret search result remains usable when details are unavailable", () => {
  const food = fatSecretFood({
    food_id: "41963",
    food_name: "Cheeseburger",
    food_description: "Per 1 sandwich - Calories: 300kcal | Fat: 13.00g | Carbs: 32.00g | Protein: 15.00g"
  });
  assert.equal(food.servings[0].label, "1 sandwich");
  assert.equal(food.servings[0].gramWeight, 0);
});

test("FatSecret does not promote a search-only weight over an available portion", () => {
  const food = fatSecretFood({
    food_id: "123",
    food_name: "Snack",
    servings: { serving: [
      { serving_id: "1", serving_description: "1 sandwich", calories: "200" },
      { serving_id: "0", serving_description: "100 g", calories: "250" }
    ] }
  }, { food_description: "Per 100 g - Calories: 250kcal" });
  assert.equal(food.servings[0].label, "1 sandwich");
});

test("USDA search records remain supplemental catalog foods", () => {
  const food = usdaFood({
    fdcId: 173944,
    description: "Bananas, raw",
    foodNutrients: [
      { nutrientName: "Energy", value: 89 },
      { nutrientName: "Carbohydrate, by difference", value: 22.8 },
      { nutrientName: "Protein", value: 1.1 },
      { nutrientName: "Total lipid (fat)", value: 0.3 }
    ]
  });
  assert.equal(food.id, "usda:173944");
  assert.equal(food.servings[0].nutrients.calories, 89);
  assert.equal(food.provenance[0].source, "USDA FoodData Central");
});

function jsonResponse(value) { return { ok: true, json: async () => value }; }
