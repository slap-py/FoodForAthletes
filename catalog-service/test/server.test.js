import test from "node:test";
import assert from "node:assert/strict";
import { server } from "../src/server.js";

test("the catalog search route returns the shape consumed by iOS", async () => {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  try {
    const address = server.address();
    const response = await fetch(`http://127.0.0.1:${address.port}/v1/foods/search?q=banana`);
    const payload = await response.json();

    assert.equal(response.status, 200);
    assert.equal(payload.foods.length, 1);
    assert.equal(payload.foods[0].canonicalName, "Bananas, Raw");
    assert.equal(payload.foods[0].servings[0].gramWeight, 118);
    assert.equal(payload.foods[0].servings[0].nutrients.calories, 105);
    assert.equal(payload.foods[0].servings[0].nutrients.vitaminD, 0);
    assert.deepEqual(payload.foods[0].provenance.map(item => item.sourceID).sort(), ["1105314", "173944"]);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});
