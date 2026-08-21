const sourceDate = "2026-08-21";

// Curated products are for high-frequency, exact branded menu items where a
// generic food database can easily return an ingredient or a different product.
// Each record must link to a first-party nutrition page and be reviewed when
// the restaurant changes its menu.
const products = [
  {
    brand: "Starbucks",
    name: "Double-Smoked Bacon, Cheddar & Egg Sandwich",
    aliases: [
      "double smoked bacon cheddar egg sandwich",
      "double smoked bacon egg and cheese sandwich",
      "starbucks double smoked bacon cheddar egg sandwich",
      "starbucks double smoked bacon egg and cheese sandwich"
    ],
    servingLabel: "1 sandwich",
    servingGrams: 148,
    sourceName: "Starbucks nutrition",
    sourceURL: "https://www.starbucks.com/menu/product/2121219/single/nutrition",
    reviewedAt: sourceDate,
    nutrientsPerServing: {
      calories: 500,
      carbohydrates: 43,
      protein: 21,
      fat: 27,
      fiber: 2,
      calcium: 0,
      iron: 0,
      magnesium: 0,
      potassium: 0,
      sodium: 960,
      vitaminD: 0
    }
  }
];

export function namedMenuProducts(description) {
  const normalizedDescription = normalize(description);
  return products.filter(product => product.aliases.some(alias => normalizedDescription.includes(normalize(alias))));
}

export function curatedMenuProduct(ingredient) {
  const candidate = normalize([ingredient.brand, ingredient.name].filter(Boolean).join(" "));
  return products.find(product => {
    const aliases = [product.name, ...product.aliases].map(normalize);
    return aliases.some(alias => candidate.includes(alias) || alias.includes(candidate));
  }) ?? null;
}

export function productIngredient(product) {
  return {
    name: product.name,
    brand: product.brand,
    kind: "branded",
    grams: product.servingGrams
  };
}

function normalize(value) {
  return String(value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}
