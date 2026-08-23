# Dayplate catalog service

This service exposes `POST /v1/meal-analysis`, `POST /v1/photo-foods`, and `POST /v1/transcribe`.

`POST /v1/meal-analysis` accepts optional text and up to three photos. It identifies meal-level ingredients and resolves every food in order through USDA FoodData Central, Open Food Facts, then AI-assisted web research. A failed request, missing configuration, weak match, or unit-invalid result advances to the next source. Product matching tolerates approximate remembered names and common flavor wording, while retaining match confidence and candidate identity. Label serving size is tracked separately from the amount eaten. The research tier prefers first-party nutrition pages, supports explicit per-serving and per-100-g bases, and records corroborating sources when available. Interactive clients can send `allowClarifications: true`; when product identity or per-item weight remains ambiguous, the completed best-guess result includes up to two optional `clarifications`. Clients can save immediately and resubmit a selected `clarificationAnswer` in the background. A separate sanity check can trigger one targeted research-and-verification repair pass for at most two specifically named ingredients instead of immediately rejecting a meal. Photo-review identifications are sent back into meal analysis as explicit hints instead of remaining UI-only. `POST /v1/photo-foods` uses `gpt-5.4-mini` by default with high image detail to list visible foods for the review screen. Text-only analyses and ingredient lookups use bounded, short-lived normalized caches so immediate repeated logs reuse the same result without unbounded memory growth. `POST /v1/transcribe` uses Whisper to turn a temporary voice recording into meal-description text.

## Configuration

Copy [`.env.example`](.env.example) into your deployment’s secret manager and set `USDA_FOODDATA_API_KEY` and `OPENAI_API_KEY`. Never place these values in the iOS app or source control.

Set the iOS `DAYPLATE_SERVICE_URL` build setting to this service’s public HTTPS URL before shipping the app. That URL is configuration only; it is not a credential.

## Cloudflare Workers

The service is configured for Workers. There is no build command: it is plain JavaScript. From this directory, use `npm run dev` for local Workers development and `npm run deploy` to deploy. The deploy command is `npx wrangler deploy`; Cloudflare reads `wrangler.jsonc` in this folder, so configure `catalog-service` as the working directory in Cloudflare Workers Builds or GitHub Actions.

For local Workers secrets, create a non-committed `.dev.vars` file with `USDA_FOODDATA_API_KEY` and `OPENAI_API_KEY`. In Cloudflare, add those two values as Worker Secrets—not plaintext Variables—before deploying. The four optional `OPENAI_*_MODEL` overrides shown in `.env.example` are ordinary configuration variables and can be omitted to use the checked-in defaults. The checked-in Worker name is `foodforathletes`, matching the workers.dev URL configured in the iOS app.

Meal analysis uses `OPENAI_MODEL` for text-only logs and `OPENAI_VISION_MODEL` (falling back to `OPENAI_PHOTO_MODEL`) whenever a meal includes one or more photos. Set the latter to a model that supports `input_image`; this split prevents a text-only model configuration from causing photo-only meals to fail as a service outage.

Ingestion groups deterministic exact keys first. `duplicateCandidates` creates only plausible later-stage candidates. An agent may return the documented structured merge/keep decision, but `applyAgentDecision` accepts an automatic merge only at high confidence when normalized identity, serving weight, and key nutrients agree. Conflicts remain separate for review, while all original records and import timestamps remain in `sourceRecords` for auditability.

## Curating exact branded menu products

Run tools/curate_menu_products.py to build a review-ready JSON catalog for one brand at a time. It asks for the brand and any official or trusted links that should guide its research, then uses OpenAI web search to find source-linked nutrition facts. It deliberately records whole purchasable products rather than breaking a named product into ingredients.

Set OPENAI_API_KEY in your shell, then run:

    cd catalog-service
    python3 tools/curate_menu_products.py

It defaults to gpt-5.6-luna with high reasoning for research, then independently checks every result with gpt-5.6-terra at xhigh reasoning before writing the JSON. The terminal streams model-provided reasoning summaries and web-search progress as each pass runs; this is a debugging summary rather than private chain-of-thought. The catalog is food-only: all drinks are excluded. A normal run defaults to 12 products, six research searches, four review searches, and a 100,000-token response budget per pass. For a full food-menu attempt in one pass, run:

    python3 tools/curate_menu_products.py --full-menu

Full-menu mode asks for up to 200 food products and raises each search cap to 14. You can instead choose a specific size with --max-products 100, increase the response budget with --max-output-tokens 120000, or adjust either verifier setting with its corresponding --review flag. The JSON is written to the directory from which you run the command, never overwriting an existing default-named file. It includes short curator and verifier notes, and keeps unknown optional nutrients as null instead of treating them as zero.

To fill a missed category into an existing catalog, use append mode. It asks for the category, excludes products already present, verifies the new batch, merges only new product names, and creates a timestamped backup before replacing the file.

    python3 tools/curate_menu_products.py --append tools/starbucks-usa-nutrition-candidates.json --category Treats
