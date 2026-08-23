import test from "node:test";
import assert from "node:assert/strict";
import { modelForMealAnalysis } from "../src/server.js";

test("meal analysis selects the vision model only when a photo is present", () => {
  assert.equal(modelForMealAnalysis({ photosBase64: [] }), "gpt-5.6-terra");
  assert.equal(modelForMealAnalysis({ photosBase64: ["base64-photo"] }), "gpt-5.4-mini");
});
