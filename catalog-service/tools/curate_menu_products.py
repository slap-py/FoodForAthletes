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
import shutil
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_URL = "https://api.openai.com/v1/responses"
DEFAULT_MODEL = "gpt-5.6-luna"
DEFAULT_REASONING = "high"
DEFAULT_REVIEW_MODEL = "gpt-5.6-terra"
DEFAULT_REVIEW_REASONING = "xhigh"
DEFAULT_RESEARCH_SEARCHES = 6
DEFAULT_REVIEW_SEARCHES = 4
DEFAULT_MAX_OUTPUT_TOKENS = 100_000
FULL_MENU_MAX_PRODUCTS = 200
FULL_MENU_MAX_SEARCHES = 14
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
    if args.full_menu:
        args.max_products = FULL_MENU_MAX_PRODUCTS
        args.max_searches = FULL_MENU_MAX_SEARCHES
        args.review_max_searches = FULL_MENU_MAX_SEARCHES
    console = Console(color=not args.no_color and sys.stdout.isatty(), quiet=args.quiet)
    console.banner()
    existing_catalog = load_existing_catalog(args.append) if args.append else None
    brand = args.brand.strip() if args.brand else existing_catalog["brand"] if existing_catalog else prompt_brand()
    if existing_catalog and not strings_match(existing_catalog["brand"], brand):
        print("The --brand value must match the brand in the file being appended.", file=sys.stderr)
        return 2
    category = args.category.strip() if args.category else prompt_category() if existing_catalog else ""
    guidance_urls = args.guidance_url or prompt_guidance_urls()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("OPENAI_API_KEY is required. Set it, then run this command again.", file=sys.stderr)
        return 2

    detail = f"{brand}  ·  {args.model}  ·  {args.reasoning}"
    console.section("Add category" if category else "Research", f"{category + '  ·  ' if category else ''}{detail}")
    try:
        response = create_catalog_response(
            api_key=api_key,
            brand=brand,
            guidance_urls=guidance_urls,
            model=args.model,
            reasoning=args.reasoning,
            max_products=args.max_products,
            max_searches=args.max_searches,
            max_output_tokens=args.max_output_tokens,
            category=category,
            existing_product_names=existing_product_names(existing_catalog),
            console=console,
        )
        draft_catalog = parse_catalog(response)
        validate_catalog(draft_catalog, brand)

        console.section("Independent review", f"{args.review_model}  ·  {args.review_reasoning}")
        review_response = create_review_response(
            api_key=api_key,
            brand=brand,
            draft_catalog=draft_catalog,
            model=args.review_model,
            reasoning=args.review_reasoning,
            max_searches=args.review_max_searches,
            max_output_tokens=args.review_max_output_tokens,
            console=console,
        )
        review = parse_review(review_response)
        catalog = combine_review(draft_catalog, review)
        validate_catalog(catalog, brand)
    except (HTTPError, URLError, ValueError, KeyError) as error:
        print(f"\nCould not create a catalog: {error}", file=sys.stderr)
        return 1

    generation = {
        "researcher": {"model": args.model, "reasoningEffort": args.reasoning},
        "reviewer": {"model": args.review_model, "reasoningEffort": args.review_reasoning},
        "guidanceURLs": guidance_urls,
    }
    if existing_catalog:
        catalog, added_count = merge_catalog(existing_catalog, catalog, category, generation)
        output_path = args.append
        backup_path = backup_catalog(output_path)
    else:
        catalog["generatedAt"] = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        catalog["generation"] = generation
        output_path = choose_output_path(args.output, brand)
        added_count = len(catalog["products"])
        backup_path = None
    output_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    products = catalog["products"]
    completion = f"{added_count} new verified product(s) · {len(products)} total" if existing_catalog else f"{len(products)} verified product(s)"
    console.section("Complete", completion)
    print(f"Saved JSON:\n  {output_path}")
    if backup_path:
        print(f"Backup:\n  {backup_path}")
    console.note("Curator note", catalog["curatorNote"])
    console.note("Verifier note", catalog["qualityReview"]["note"])
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
        "--append",
        type=Path,
        help="Add a focused batch to this existing catalog file (a timestamped backup is made first).",
    )
    parser.add_argument(
        "--category",
        help="Food category to add, for example Treats or Bakery. Required interactively with --append.",
    )
    parser.add_argument(
        "--max-products",
        type=int,
        default=12,
        choices=range(1, FULL_MENU_MAX_PRODUCTS + 1),
        metavar="1-200",
        help="Maximum number of products to collect (default: 12).",
    )
    parser.add_argument(
        "--max-searches",
        type=int,
        default=DEFAULT_RESEARCH_SEARCHES,
        choices=range(1, 21),
        metavar="1-20",
        help=f"Maximum web searches for the research pass (default: {DEFAULT_RESEARCH_SEARCHES}).",
    )
    parser.add_argument(
        "--review-max-searches",
        type=int,
        default=DEFAULT_REVIEW_SEARCHES,
        choices=range(1, 21),
        metavar="1-20",
        help=f"Maximum web searches for the review pass (default: {DEFAULT_REVIEW_SEARCHES}).",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=output_token_limit,
        default=DEFAULT_MAX_OUTPUT_TOKENS,
        help=f"Research response budget, including reasoning (default: {DEFAULT_MAX_OUTPUT_TOKENS}).",
    )
    parser.add_argument(
        "--review-max-output-tokens",
        type=output_token_limit,
        default=DEFAULT_MAX_OUTPUT_TOKENS,
        help=f"Reviewer response budget, including reasoning (default: {DEFAULT_MAX_OUTPUT_TOKENS}).",
    )
    parser.add_argument(
        "--full-menu",
        action="store_true",
        help=f"Request up to {FULL_MENU_MAX_PRODUCTS} food products with expanded search caps.",
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
    parser.add_argument("--no-color", action="store_true", help="Turn off terminal colors and styling.")
    parser.add_argument("--quiet", action="store_true", help="Hide streamed research and reasoning summaries.")
    args = parser.parse_args()
    if args.append and args.output:
        parser.error("--append already chooses the output file; do not also pass --output.")
    if args.category and not args.category.strip():
        parser.error("--category cannot be blank.")
    return args


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


def prompt_category() -> str:
    while True:
        category = input("Which food category should be added to this catalog? ").strip()
        if category:
            return category
        print("Please name a food category, such as Treats, Bakery, or Lunch.")


def create_catalog_response(
    *,
    api_key: str,
    brand: str,
    guidance_urls: list[str],
    model: str,
    reasoning: str,
    max_products: int,
    max_searches: int,
    max_output_tokens: int,
    category: str,
    existing_product_names: list[str],
    console: "Console",
) -> dict[str, Any]:
    prompt = build_research_prompt(brand, guidance_urls, max_products, category, existing_product_names)
    return create_structured_response(
        api_key=api_key,
        prompt=prompt,
        model=model,
        reasoning=reasoning,
        schema_name="dayplate_menu_product_catalog",
        schema=catalog_schema(),
        max_tool_calls=max_searches,
        max_output_tokens=max_output_tokens,
        console=console,
    )


def create_review_response(
    *,
    api_key: str,
    brand: str,
    draft_catalog: dict[str, Any],
    model: str,
    reasoning: str,
    max_searches: int,
    max_output_tokens: int,
    console: "Console",
) -> dict[str, Any]:
    return create_structured_response(
        api_key=api_key,
        prompt=build_review_prompt(brand, draft_catalog),
        model=model,
        reasoning=reasoning,
        schema_name="dayplate_menu_product_review",
        schema=review_schema(),
        max_tool_calls=max_searches,
        max_output_tokens=max_output_tokens,
        console=console,
    )


def create_structured_response(
    *,
    api_key: str,
    prompt: str,
    model: str,
    reasoning: str,
    schema_name: str,
    schema: dict[str, Any],
    max_tool_calls: int,
    max_output_tokens: int,
    console: "Console",
) -> dict[str, Any]:
    payload = {
        "model": model,
        "reasoning": {"effort": reasoning, "summary": "concise"},
        "tools": [{"type": "web_search", "search_context_size": "medium"}],
        "max_tool_calls": max_tool_calls,
        "max_output_tokens": max_output_tokens,
        "include": ["web_search_call.action.sources"],
        "store": False,
        "stream": True,
        "input": prompt,
        "text": {"format": {"type": "json_schema", "name": schema_name, "strict": True, "schema": schema}},
    }
    request = Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=300) as http_response:
            return read_response_stream(http_response, console)
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise ValueError(f"OpenAI API returned HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise ValueError(f"Could not reach the OpenAI API: {error.reason}") from error


def build_research_prompt(
    brand: str,
    guidance_urls: list[str],
    max_products: int,
    category: str = "",
    existing_product_names: list[str] | None = None,
) -> str:
    supplied_urls = "\n".join(f"- {url}" for url in guidance_urls) or "- None supplied"
    existing_names = existing_product_names or []
    if max_products > 12:
        scope = (
            f"Aim to cover the current food menu, up to {max_products} distinct products. "
            "Prefer a complete official food/menu nutrition source over chasing individual pages."
        )
    else:
        scope = (
            f"Return a small, review-ready catalog of at most {max_products} familiar menu products. "
            "A verified batch of 4–12 products is successful."
        )
    category_instruction = (
        f"Focus exclusively on the {category!r} food category. Return only products in that category."
        if category
        else ""
    )
    existing_instruction = (
        "These products are already in the catalog. Do not return them again:\n"
        + "\n".join(f"- {name}" for name in existing_names)
        if existing_names
        else ""
    )
    return f"""You are curating reliable nutrition data for Dayplate.

Research current, whole purchasable FOOD products for the brand {brand!r}. {scope}
Use web search to find a nutrition hub or product pages, then select only products those
sources directly support. The supplied links below are guidance, not evidence by themselves:
{supplied_urls}

{category_instruction}
{existing_instruction}

Set schemaVersion to exactly {SCHEMA_VERSION!r}.

Rules:
- Each product is exactly one branded product a person can order or buy. Never split a
  named sandwich, drink, entree, packaged item, or bakery item into ingredients.
- This catalog is FOOD ONLY. Exclude every beverage, including coffee, tea, espresso,
  refreshers, juice, smoothies, bottled drinks, and any customizable drink. Do not
  return a drink even if it is paired with food or has substantial calories.
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
- Search deliberately: find the official nutrition hub first, then reuse the resulting
  source system to choose a small batch. Do not keep searching for a missing product;
  omit it and proceed with the verified products you already have.
- curatorNote must be a brief, plain-language note describing coverage and any important
  caveat for the person reviewing this file. Do not expose private chain-of-thought.
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
product source is a fallback. reviewNote must briefly state what you verified or what
limits remain; do not expose private chain-of-thought. Return only the schema requested.

This is a FOOD-ONLY catalog. Remove all beverages from the draft and do not introduce
any coffee, tea, espresso, refresher, juice, smoothie, or bottled drink.

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
            "curatorNote": {"type": "string"},
        },
        "required": ["schemaVersion", "brand", "products", "omissions", "curatorNote"],
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
            "reviewNote": {"type": "string"},
        },
        "required": ["products", "rejections", "reviewNote"],
    }


def parse_catalog(response: dict[str, Any]) -> dict[str, Any]:
    output_text = extract_output_text(response)
    if not output_text:
        status = response.get("status", "unknown")
        raise ValueError(f"The API returned no structured output (status: {status}).")
    try:
        return json.loads(output_text)
    except json.JSONDecodeError as error:
        raise ValueError("The API returned malformed JSON.") from error


def parse_review(response: dict[str, Any]) -> dict[str, Any]:
    review = parse_catalog(response)
    if (
        not isinstance(review.get("products"), list)
        or not isinstance(review.get("rejections"), list)
        or not isinstance(review.get("reviewNote"), str)
    ):
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
        "curatorNote": draft_catalog["curatorNote"],
        "qualityReview": {
            "reviewedProducts": len(review["products"]),
            "rejectedProducts": len(reviewer_rejections),
            "note": review["reviewNote"],
        },
    }


def validate_catalog(catalog: dict[str, Any], requested_brand: str) -> None:
    if catalog.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"Expected schema version {SCHEMA_VERSION}.")
    if not strings_match(catalog.get("brand"), requested_brand):
        raise ValueError("Returned catalog brand does not match the brand requested.")
    if not isinstance(catalog.get("products"), list):
        raise ValueError("Returned catalog does not contain a products list.")
    if not isinstance(catalog.get("curatorNote"), str):
        raise ValueError("Returned catalog does not contain a curator note.")

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


def load_existing_catalog(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"Append file does not exist: {path}")
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"Append file is not valid JSON: {path}") from error
    validate_catalog(catalog, catalog.get("brand", ""))
    return catalog


def existing_product_names(catalog: dict[str, Any] | None) -> list[str]:
    if not catalog:
        return []
    return [product["name"] for product in catalog["products"]]


def merge_catalog(
    existing: dict[str, Any],
    addition: dict[str, Any],
    category: str,
    generation: dict[str, Any],
) -> tuple[dict[str, Any], int]:
    known_names = {normalize(product["name"]) for product in existing["products"]}
    new_products = [product for product in addition["products"] if normalize(product["name"]) not in known_names]
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    append_history = list(existing.get("appendHistory", []))
    append_history.append(
        {
            "addedAt": now,
            "category": category,
            "addedProducts": len(new_products),
            "generation": generation,
            "curatorNote": addition["curatorNote"],
            "verifierNote": addition["qualityReview"]["note"],
        }
    )
    merged = {
        **existing,
        "products": [*existing["products"], *new_products],
        "omissions": [*existing.get("omissions", []), *addition["omissions"]],
        "updatedAt": now,
        "appendHistory": append_history,
    }
    return merged, len(new_products)


def backup_catalog(path: Path) -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.stem}.backup-{stamp}{path.suffix}")
    shutil.copy2(path, backup)
    return backup


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "brand"


def strings_match(left: Any, right: Any) -> bool:
    return normalize(left) == normalize(right)


def normalize(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(value or "").lower()).strip()


def extract_output_text(response: dict[str, Any]) -> str:
    """Read output text from either an SDK response or raw Responses API JSON."""
    if isinstance(response.get("output_text"), str) and response["output_text"]:
        return response["output_text"]

    text_parts: list[str] = []
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if content.get("type") == "output_text" and isinstance(content.get("text"), str):
                text_parts.append(content["text"])
    return "".join(text_parts)


def read_response_stream(http_response: Any, console: "Console") -> dict[str, Any]:
    """Consume Responses API SSE while showing model-provided progress summaries."""
    completed_response: dict[str, Any] | None = None
    for raw_line in http_response:
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        data = line.removeprefix("data:").strip()
        if not data or data == "[DONE]":
            continue
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue

        event_type = event.get("type", "")
        if event_type == "response.reasoning_summary_text.delta":
            console.reasoning(event.get("delta", ""))
        elif event_type == "response.web_search_call.searching":
            console.progress("Searching the web")
        elif event_type == "response.web_search_call.completed":
            console.progress("Search complete")
        elif event_type == "response.completed":
            completed_response = event.get("response")
        elif event_type in {"response.failed", "response.incomplete"}:
            response = event.get("response", {})
            error = response.get("error", {})
            detail = error.get("message") or response.get("incomplete_details", {}).get("reason")
            raise ValueError(f"The API did not complete the response: {detail or event_type}.")
        elif event_type == "error":
            raise ValueError(stream_error_detail(event))

    console.finish_stream()
    if completed_response is None:
        raise ValueError("The API stream ended before returning a completed response.")
    return completed_response


def stream_error_detail(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict) and isinstance(error.get("message"), str):
        return error["message"]
    if isinstance(event.get("message"), str):
        return event["message"]
    return "The API returned a streaming error without a message."


def output_token_limit(value: str) -> int:
    try:
        tokens = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a whole number") from error
    if not 8_000 <= tokens <= 120_000:
        raise argparse.ArgumentTypeError("must be between 8,000 and 120,000")
    return tokens


class Console:
    """Small terminal UI with optional ANSI color and live reasoning summaries."""

    def __init__(self, *, color: bool, quiet: bool) -> None:
        self.color = color
        self.quiet = quiet
        self._reasoning_open = False

    def banner(self) -> None:
        title = self.paint("DAYPLATE  ·  NUTRITION CURATOR", "1;38;5;28")
        subtitle = self.paint("Whole products · sourced facts · independent verification", "38;5;246")
        print(f"\n╭──────────────────────────────────────────────────────────────╮\n│  {title:<60}│\n│  {subtitle:<60}│\n╰──────────────────────────────────────────────────────────────╯\n")

    def section(self, title: str, detail: str) -> None:
        self.finish_stream()
        print(f"\n{self.paint('◆ ' + title, '1;38;5;28')}  {self.paint(detail, '38;5;246')}")

    def progress(self, message: str) -> None:
        if not self.quiet:
            self.finish_stream()
            print(f"  {self.paint('↳', '38;5;178')} {message}…")

    def reasoning(self, delta: str) -> None:
        if self.quiet or not delta:
            return
        delta = delta.replace("**", "")
        if not self._reasoning_open:
            print(f"  {self.paint('↳ Model note: ', '38;5;178')}", end="", flush=True)
            self._reasoning_open = True
        print(self.paint(delta, '38;5;246'), end="", flush=True)

    def finish_stream(self) -> None:
        if self._reasoning_open:
            print()
            self._reasoning_open = False

    def note(self, label: str, message: str) -> None:
        print(f"{self.paint(label + ':', '1;38;5;28')} {message}")

    def paint(self, text: str, code: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.color else text


if __name__ == "__main__":
    raise SystemExit(main())
