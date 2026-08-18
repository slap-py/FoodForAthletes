import test from "node:test";
import assert from "node:assert/strict";
import { foods, search } from "../src/catalog.js";

test("duplicate source records collapse with provenance", () => {
  const bananas = search("banana");
  assert.equal(bananas.length, 1);
  assert.deepEqual(bananas[0].sourceRecords.map(record => record.sourceID).sort(), ["1105314", "173944"]);
});

test("generic and branded records are searchable", () => {
  assert.equal(search("chicken").length, 1);
  assert.equal(search("General Mills")[0].brand, "General Mills");
  assert.equal(foods.every(food => food.catalogVersion), true);
});
