#!/usr/bin/env python3
"""Create a review-ready branded-menu nutrition catalog with OpenAI web search.

The generated JSON deliberately stores whole purchasable menu products. It is a
curation input for Dayplate's exact-product registry, not an ingredient recipe.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_URL = "https://api.openai.com/v1/responses"
DEFAULT_MODEL = "gpt-5.6-luna"
DEFAULT_REASONING = "high"
DEFAULT_REVIEW_MODEL = "gpt-5.6-sol"
DEFAULT_REVIEW_REASONING = "xhigh"
SCHEMA_VERSION = "dayplate.menu-product-candidate.v1"

NUTRIENT_FIELDS = (
    "calories",
    "carbohydrates",
    "protein",
    "fat",
    "fiber",
    "calcium",
    "iron",
    "magnesium",
    "potassium",
    "sodium",
    "vitaminD",
)


def main() -> int:
    args = parse_args()
    brand = args.brand.strip() if args.brand else prompt_brand()
    guidance_urls = args.guidance_url or prompt_guidance_urls()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("OPENAI_API_KEY is required. Set it, then run this command again.", file=sys.stderr)
        return 2

    print(f"\nResearching {brand} with {args.model} ({args.reasoning})…")
    try:
        response = create_catalog_response(
            api_key=api_key,
            brand=brand,
            guidance_urls=guidance_urls,
            model=args.model,
            reasoning=args.reasoning,
            max_products=args.max_products,
        )
        draft_catalog = parse_catalog(response)
        validate_catalog(draft_catalog, brand)

        print(f"Independently checking the draft with {args.review_model} ({args.review_reasoning})…")
        review_response = create_review_response(
            api_key=api_key,
            brand=brand,
            draft_catalog=draft_catalog,
            model=args.review_model,
            reasoning=args.review_reasoning,
        )
        review = parse_review(review_response)
        catalog = combine_review(draft_catalog, review)
        validate_catalog(catalog, brand)
    except (HTTPError, URLError, ValueError, KeyError) as error:
        print(f"\nCould not create a catalog: {error}", file=sys.stderr)
        return 1

    catalog["generatedAt"] = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    catalog["generation"] = {
        "researcher": {"model": args.model, "reasoningEffort": args.reasoning},
        "reviewer": {"model": args.review_model, "reasoningEffort": args.review_reasoning},
        "guidanceURLs": guidance_urls,
    }
    output_path = choose_output_path(args.output, brand)
    output_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    products = catalog["products"]
    print(f"\nSaved {len(products)} product(s) to:\n  {output_path}")
    if catalog["omissions"]:
        print(f"{len(catalog['omissions'])} item(s) were skipped because complete, source-linked data was not found.")
    print("Review the JSON before adding records to src/menuProducts.js.")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Research a brand's whole menu products into Dayplate's review-ready JSON schema."
    )
    parser.add_argument("--brand", help="Skip the interactive brand prompt.")
    parser.add_argument(
        "--guidance-url",
        action="append",
        default=[],
        help="A first-party or trusted nutrition URL to prioritize. Repeat for more than one.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the JSON. Defaults to a new file in the current directory.",
    )
    parser.add_argument(
        "--max-products",
        type=int,
        default=20,
        choices=range(1, 51),
        metavar="1-50",
        help="Maximum number of products to collect (default: 20).",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("DAYPLATE_CURATION_MODEL", DEFAULT_MODEL),
        help=f"Responses API model (default: {DEFAULT_MODEL}).",
    )
    parser.add_argument(
        "--reasoning",
        choices=("none", "low", "medium", "high", "xhigh", "max"),
        default=os.environ.get("DAYPLATE_CURATION_REASONING", DEFAULT_REASONING),
        help=f"Reasoning effort (default: {DEFAULT_REASONING}).",
    )
    parser.add_argument(
        "--review-model",
        default=os.environ.get("DAYPLATE_CURATION_REVIEW_MODEL", DEFAULT_REVIEW_MODEL),
        help=f"Independent verifier model (default: {DEFAULT_REVIEW_MODEL}).",
    )
    parser.add_argument(
        "--review-reasoning",
        choices=("none", "low", "medium", "high", "xhigh", "max"),
        default=os.environ.get("DAYPLATE_CURATION_REVIEW_REASONING", DEFAULT_REVIEW_REASONING),
        help=f"Independent verifier reasoning effort (default: {DEFAULT_REVIEW_REASONING}).",
    )
    return parser.parse_args()


def prompt_brand() -> str:
    while True:
        brand = input("What brand are you looking to get nutrition data for? ").strip()
        if brand:
            return brand
        print("Please enter a brand name.")


def prompt_guidance_urls() -> list[str]:
    print("\nDo you have links or websites that should guide the search?")
    print("Paste one URL per line, then press Return on a blank line. Leave blank to use web search.")
    urls: list[str] = []
    while True:
        value = input("> ").strip()
        if not value:
            return urls
        if not value.startswith(("https://", "http://")):
            print("Please enter a full http(s) URL, or press Return to finish.")
            continue
        urls.append(value)


def create_catalog_response(
    *,
    api_key: str,
    brand: str,
    guidance_urls: list[str],
    model: str,
    reasoning: str,
    max_products: int,
) -> dict[str, Any]:
    prompt = build_research_prompt(brand, guidance_urls, max_products)
    return create_structured_response(
        api_key=api_key,
        prompt=prompt,
        model=model,
        reasoning=reasoning,
        schema_name="dayplate_menu_product_catalog",
        schema=catalog_schema(),
    )


def create_review_response(
    *,
    api_key: str,
    brand: str,
    draft_catalog: dict[str, Any],
    model: str,
    reasoning: str,
) -> dict[str, Any]:
    return create_structured_response(
        api_key=api_key,
        prompt=build_review_prompt(brand, draft_catalog),
        model=model,
        reasoning=reasoning,
        schema_name="dayplate_menu_product_review",
        schema=review_schema(),
    )


def create_structured_response(
    *,
    api_key: str,
    prompt: str,
    model: str,
    reasoning: str,
    schema_name: str,
    schema: dict[str, Any],
) -> dict[str, Any]:
    payload = {
        "model": model,
        "reasoning": {"effort": reasoning},
        "tools": [{"type": "web_search"}],
        "include": ["web_search_call.action.sources"],
        "store": False,
        "input": prompt,
        "text": {"format": {"type": "json_schema", "name": schema_name, "strict": True, "schema": schema}},
    }
    request = Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=300) as http_response:
            return json.load(http_response)
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise ValueError(f"OpenAI API returned HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise ValueError(f"Could not reach the OpenAI API: {error.reason}") from error


def build_research_prompt(brand: str, guidance_urls: list[str], max_products: int) -> str:
    supplied_urls = "\n".join(f"- {url}" for url in guidance_urls) or "- None supplied"
    return f"""You are curating reliable nutrition data for Dayplate.

Research current, whole purchasable products for the brand {brand!r}. Return a small,
review-ready catalog of at most {max_products} familiar menu products; this is not an
exhaustive crawl. Use web search. The supplied links below are guidance, not evidence
by themselves:
{supplied_urls}

Set schemaVersion to exactly {SCHEMA_VERSION!r}.

Rules:
- Each product is exactly one branded product a person can order or buy. Never split a
  named sandwich, drink, entree, packaged item, or bakery item into ingredients.
- Do not invent a recipe or estimate from components. If the complete nutrition facts
  for one product cannot be found, omit it and say why in omissions.
- Prefer a current first-party nutrition page, PDF, or product page. A reputable
  publisher is acceptable only when it clearly identifies the exact product and serving.
- Record nutrient values per the listed consumer serving, not per 100 g. Do not round
  source values except to a sensible displayed whole/decimal nutrition-label value.
- calories, carbohydrates, protein, and fat must be known for every returned product.
  Optional nutrients may be null when the source does not publish them; do not use zero
  to mean unknown.
- Use the brand spelling in the request for product.brand. Include practical aliases
  that improve exact matching, but never include component ingredients as aliases.
- source.url must directly support that particular product's nutrition facts.
"""


def build_review_prompt(brand: str, draft_catalog: dict[str, Any]) -> str:
    draft = json.dumps(draft_catalog, indent=2, ensure_ascii=False)
    return f"""You are Dayplate's independent nutrition-data verifier. Use web search to
audit the proposed menu-product catalog below for {brand!r}. Do not trust its values
or sources simply because they appear in the draft.

For each proposed product, independently find a direct source for that exact product
and serving. Keep it only if its calories, carbohydrates, protein, and fat are
supported by the source. Correct the product's nutrition, serving, aliases, source, or
notes whenever your verification finds a better fact. Omit a product entirely when it
cannot be verified; add a plain explanation to rejections. Do not add new products.

Products must remain whole purchasable menu items: never split a branded sandwich,
drink, entree, packaged item, or bakery item into its ingredients. Unknown optional
nutrients must remain null, not zero. Prefer first-party sources; a reputable exact
product source is a fallback. Return only the schema requested.

Draft to audit:
{draft}
"""


def catalog_schema() -> dict[str, Any]:
    nullable_number = {"type": ["number", "null"]}
    nutrients = {
        "type": "object",
        "additionalProperties": False,
        "properties": {field: nullable_number for field in NUTRIENT_FIELDS},
        "required": list(NUTRIENT_FIELDS),
    }
    source = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "name": {"type": "string"},
            "url": {"type": "string"},
            "isFirstParty": {"type": "boolean"},
            "accessedDate": {"type": "string"},
        },
        "required": ["name", "url", "isFirstParty", "accessedDate"],
    }
    product = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "brand": {"type": "string"},
            "name": {"type": "string"},
            "aliases": {"type": "array", "items": {"type": "string"}},
            "servingLabel": {"type": "string"},
            "servingGrams": nullable_number,
            "source": source,
            "nutrientsPerServing": nutrients,
            "notes": {"type": "string"},
        },
        "required": [
            "brand",
            "name",
            "aliases",
            "servingLabel",
            "servingGrams",
            "source",
            "nutrientsPerServing",
            "notes",
        ],
    }
    omission = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"name": {"type": "string"}, "reason": {"type": "string"}},
        "required": ["name", "reason"],
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "schemaVersion": {"type": "string", "enum": [SCHEMA_VERSION]},
            "brand": {"type": "string"},
            "products": {"type": "array", "items": product},
            "omissions": {"type": "array", "items": omission},
        },
        "required": ["schemaVersion", "brand", "products", "omissions"],
    }


def review_schema() -> dict[str, Any]:
    product_schema = catalog_schema()["properties"]["products"]["items"]
    rejection_schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {"name": {"type": "string"}, "reason": {"type": "string"}},
        "required": ["name", "reason"],
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "products": {"type": "array", "items": product_schema},
            "rejections": {"type": "array", "items": rejection_schema},
        },
        "required": ["products", "rejections"],
    }


def parse_catalog(response: dict[str, Any]) -> dict[str, Any]:
    output_text = response.get("output_text")
    if not output_text:
        status = response.get("status", "unknown")
        raise ValueError(f"The API returned no structured output (status: {status}).")
    try:
        return json.loads(output_text)
    except json.JSONDecodeError as error:
        raise ValueError("The API returned malformed JSON.") from error


def parse_review(response: dict[str, Any]) -> dict[str, Any]:
    review = parse_catalog(response)
    if not isinstance(review.get("products"), list) or not isinstance(review.get("rejections"), list):
        raise ValueError("The independent reviewer returned an invalid review.")
    return review


def combine_review(draft_catalog: dict[str, Any], review: dict[str, Any]) -> dict[str, Any]:
    reviewer_rejections = review["rejections"]
    omissions = [*draft_catalog["omissions"], *reviewer_rejections]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "brand": draft_catalog["brand"],
        "products": review["products"],
        "omissions": omissions,
        "qualityReview": {
            "reviewedProducts": len(review["products"]),
            "rejectedProducts": len(reviewer_rejections),
        },
    }


def validate_catalog(catalog: dict[str, Any], requested_brand: str) -> None:
    if catalog.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"Expected schema version {SCHEMA_VERSION}.")
    if not strings_match(catalog.get("brand"), requested_brand):
        raise ValueError("Returned catalog brand does not match the brand requested.")
    if not isinstance(catalog.get("products"), list):
        raise ValueError("Returned catalog does not contain a products list.")

    names: set[str] = set()
    for product in catalog["products"]:
        if not strings_match(product.get("brand"), requested_brand):
            raise ValueError(f"Product brand mismatch for {product.get('name', 'an unnamed product')}.")
        name = product.get("name")
        normalized_name = normalize(name)
        if not normalized_name or normalized_name in names:
            raise ValueError("Every returned product must have a unique name.")
        names.add(normalized_name)
        source_url = product.get("source", {}).get("url", "")
        if not source_url.startswith(("https://", "http://")):
            raise ValueError(f"{name} is missing a direct source URL.")
        nutrients = product.get("nutrientsPerServing", {})
        for required in ("calories", "carbohydrates", "protein", "fat"):
            if not isinstance(nutrients.get(required), (int, float)):
                raise ValueError(f"{name} is missing required nutrient {required}.")


def choose_output_path(requested_path: Path | None, brand: str) -> Path:
    if requested_path:
        requested_path.parent.mkdir(parents=True, exist_ok=True)
        return requested_path

    stem = f"{slugify(brand)}-nutrition-candidates"
    candidate = Path.cwd() / f"{stem}.json"
    index = 2
    while candidate.exists():
        candidate = Path.cwd() / f"{stem}-{index}.json"
        index += 1
    return candidate


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "brand"


def strings_match(left: Any, right: Any) -> bool:
    return normalize(left) == normalize(right)


def normalize(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(value or "").lower()).strip()


if __name__ == "__main__":
    raise SystemExit(main())
