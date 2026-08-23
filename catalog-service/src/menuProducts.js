const sourceDate = "2026-08-23";

// Curated products are for high-frequency, exact branded menu items where a
// generic food database can easily return an ingredient or a different product.
// Each record must link to a first-party nutrition page and be reviewed when
// the restaurant changes its menu.
const products = [
  {
    brand: "Pop-Tarts",
    name: "Frosted Chocolate Fudge Pop-Tarts",
    aliases: [
      "frosted chocolate fudge pop tarts",
      "chocolate fudge pop tarts",
      "chocolate chocolate pop tarts",
      "one container of chocolate pop tarts"
    ],
    servingLabel: "2 pastries",
    servingCount: 2,
    servingGrams: 96,
    sourceName: "Pop-Tarts nutrition",
    sourceURL: "https://www.poptarts.com/en_US/products/all-flavors/pop-tarts-frosted-chocolate-fudge-product.html",
    reviewedAt: sourceDate,
    nutrientsPerServing: {
      calories: 370,
      carbohydrates: 69,
      protein: 4,
      fat: 9,
      fiber: 2,
      calcium: 40,
      iron: 1.5,
      magnesium: 0,
      potassium: 200,
      sodium: 410,
      vitaminD: 0
    }
  },
  {
    brand: "Kellogg's",
    name: "Pop Tarts Frosted Chocotastic",
    aliases: [
      "pop tarts frosted chocotastic",
      "frosted chocotastic pop tarts",
      "chocotastic pop tarts"
    ],
    servingLabel: "1 pastry",
    servingCount: 1,
    servingGrams: 48,
    sourceName: "Kellogg's nutrition",
    sourceURL: "https://www.kelloggs.co.uk/en_GB/products/pop-tart-chocotastic.html",
    reviewedAt: sourceDate,
    nutrientsPerServing: {
      calories: 189,
      carbohydrates: 35,
      protein: 2,
      fat: 4.6,
      fiber: 0.8,
      calcium: 0,
      iron: 0,
      magnesium: 0,
      potassium: 0,
      sodium: 172,
      vitaminD: 0
    }
  },
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
    servingCount: 1,
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

export function productIngredient(product, description = "") {
  const count = explicitCount(description) ?? product.servingCount ?? 1;
  const gramsPerItem = product.servingGrams / (product.servingCount ?? 1);
  return {
    name: product.name,
    brand: product.brand,
    kind: "branded",
    grams: gramsPerItem * count,
    quantity: count,
    quantityUnit: product.servingCount > 1 || /pastr/i.test(product.servingLabel) ? "pastry" : null,
    quantityWasExplicit: explicitCount(description) != null,
    amountConfidence: "high"
  };
}

function explicitCount(description) {
  const match = String(description).match(/(?:^|\s)(\d+(?:\.\d+)?)\s+(?:frosted\s+)?(?:chocolate\s+|chocotastic\s+|fudge\s+)*pop[ -]?tarts?\b/i);
  const count = Number(match?.[1]);
  return Number.isFinite(count) && count > 0 ? count : null;
}

function normalize(value) {
  return String(value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}
