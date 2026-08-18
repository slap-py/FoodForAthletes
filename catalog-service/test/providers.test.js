import test from "node:test";
import assert from "node:assert/strict";
import { fatSecretFood, usdaFood } from "../src/providers.js";

test("FatSecret search records become app catalog foods", () => {
  const food = fatSecretFood({
    food_id: "41963",
    food_name: "Cheeseburger",
    brand_name: "McDonald's",
    food_description: "Per 1 serving - Calories: 300kcal | Fat: 13.00g | Carbs: 32.00g | Protein: 15.00g"
  });
  assert.equal(food.id, "fatsecret:41963");
  assert.equal(food.servings[0].label, "1 serving");
  assert.deepEqual(food.servings[0].nutrients, { calories: 300, carbohydrates: 32, protein: 15, fat: 13, fiber: 0, calcium: 0, iron: 0, magnesium: 0, potassium: 0, sodium: 0, vitaminD: 0 });
  assert.equal(food.provenance[0].source, "FatSecret");
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
