import { createHash } from "node:crypto";

export const catalogVersion = "dayplate-usda-2026.08-v1";

const sourceRecords = [
  source("foundation", "173944", "Bananas, raw", null, 105, 27, 1.3, 0.4, 3.1),
  source("fndds", "1105314", "Banana, raw", null, 105, 27, 1.3, 0.4, 3.1),
  source("foundation", "171077", "Chicken, broilers or fryers, breast, meat only, cooked, roasted", null, 140, 0, 26, 3, 0),
  source("branded", "2340765", "CHEERIOS ORIGINAL CEREAL", "General Mills", 140, 29, 5, 2.5, 4, 190)
];

export const foods = buildCatalog(sourceRecords);

export function exactKey(record) {
  return [normalize(record.name), normalize(record.brand ?? ""), record.serving.grams].join("|");
}

export function buildCatalog(records, agentDecisions = []) {
  const groups = new Map();
  for (const record of records) {
    const key = exactKey(record);
    const list = groups.get(key) ?? [];
    list.push(record);
    groups.set(key, list);
  }

  const canonical = [...groups.values()].map(mergeExactGroup);
  for (const decision of agentDecisions) applyAgentDecision(canonical, records, decision);
  return canonical;
}

export function duplicateCandidates(records) {
  const candidates = [];
  for (let left = 0; left < records.length; left++) {
    for (let right = left + 1; right < records.length; right++) {
      if (exactKey(records[left]) === exactKey(records[right])) continue;
      const a = new Set(normalize(records[left].name).split(" "));
      const b = new Set(normalize(records[right].name).split(" "));
      const overlap = [...a].filter(token => b.has(token)).length / Math.max(a.size, b.size);
      if (overlap >= 0.5) candidates.push({ leftSourceID: records[left].sourceID, rightSourceID: records[right].sourceID, reason: "token_similarity", score: overlap });
    }
  }
  return candidates;
}

// Agent output contract: {leftSourceID,rightSourceID,decision:"merge"|"keep",confidence,reason}.
// A merge is accepted only after this deterministic safety gate; every source remains in provenance.
export function applyAgentDecision(canonical, records, decision) {
  if (decision.decision !== "merge" || decision.confidence < 0.9) return { accepted: false, review: true };
  const left = records.find(record => record.sourceID === decision.leftSourceID);
  const right = records.find(record => record.sourceID === decision.rightSourceID);
  if (!left || !right || !sameIdentity(left, right) || !nutrientsAgree(left.nutrients, right.nutrients)) return { accepted: false, review: true };
  const leftFood = canonical.find(food => food.sourceRecords.some(record => record.sourceID === left.sourceID));
  const rightIndex = canonical.findIndex(food => food.sourceRecords.some(record => record.sourceID === right.sourceID));
  if (!leftFood || rightIndex < 0 || leftFood === canonical[rightIndex]) return { accepted: false, review: false };
  leftFood.sourceRecords.push(...canonical[rightIndex].sourceRecords);
  canonical.splice(rightIndex, 1);
  return { accepted: true, review: false };
}

export function search(query) {
  const needle = normalize(query);
  if (!needle) return [];
  return foods.map(food => {
    const key = normalize(`${food.name} ${food.brand ?? ""}`);
    const exact = key === needle || normalize(food.name) === needle;
    const prefix = key.startsWith(needle);
    const tokens = needle.split(" ");
    const overlap = tokens.filter(token => key.includes(token)).length;
    return { food, rank: exact ? 0 : prefix ? 1 : overlap ? 10 - overlap : Infinity };
  }).filter(result => Number.isFinite(result.rank)).sort((a, b) => a.rank - b.rank || a.food.name.localeCompare(b.food.name)).map(result => result.food);
}

export function foodDetail(id) { return foods.find(food => food.id === id); }

function mergeExactGroup(group) {
  const preferred = [...group].sort((a, b) => sourcePriority(a.source) - sourcePriority(b.source))[0];
  return {
    id: `food_${createHash("sha256").update(exactKey(preferred)).digest("hex").slice(0, 16)}`,
    name: titleCase(preferred.name),
    brand: preferred.brand,
    servings: [preferred.serving],
    nutrients: preferred.nutrients,
    sourceRecords: group,
    catalogVersion
  };
}

function sameIdentity(a, b) { return normalize(a.name) === normalize(b.name) && normalize(a.brand ?? "") === normalize(b.brand ?? "") && Math.abs(a.serving.grams - b.serving.grams) <= 1; }
function nutrientsAgree(a, b) { return ["calories", "carbohydrates", "protein", "fat"].every(key => relativeDifference(a[key], b[key]) <= 0.1); }
function relativeDifference(a, b) { return Math.abs(a - b) / Math.max(Math.abs(a), Math.abs(b), 1); }
function sourcePriority(value) { return ({ foundation: 0, fndds: 1, branded: 2 })[value] ?? 9; }
function normalize(value) { return value.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, " ").trim().split(" ").map(token => token.length > 3 && token.endsWith("s") ? token.slice(0, -1) : token).join(" "); }
function titleCase(value) { return value.toLowerCase().replace(/\b\w/g, character => character.toUpperCase()); }
function source(sourceName, sourceID, name, brand, calories, carbohydrates, protein, fat, fiber, sodium = 0) {
  return { source: sourceName, sourceID, name, brand, serving: { label: name.toLowerCase().includes("cereal") ? "1½ cups" : "1 serving", grams: name.toLowerCase().includes("banana") ? 118 : name.toLowerCase().includes("chicken") ? 85 : 39 }, nutrients: { calories, carbohydrates, protein, fat, fiber, sodium }, importedAt: "2026-08-17T00:00:00Z" };
}
