import test from "node:test";
import assert from "node:assert/strict";
import { fatSecretFood, usdaFood } from "../src/providers.js";

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
