# Dayplate catalog service

This service exposes `POST /v1/meal-analysis` and `POST /v1/transcribe`.

`POST /v1/meal-analysis` accepts optional text and up to three photos. It identifies meal-level ingredients, sources generic food data from USDA FoodData Central’s full search corpus, and resolves branded food data in order through USDA Branded Food Products, Open Food Facts, then manufacturer websites through an OpenAI web-search fallback. A separate GPT sanity check runs after each meal analysis. `POST /v1/transcribe` uses Whisper to turn a temporary voice recording into meal-description text.

## Configuration

Copy [`.env.example`](.env.example) into your deployment’s secret manager and set `USDA_FOODDATA_API_KEY` and `OPENAI_API_KEY`. Never place these values in the iOS app or source control.

Set the iOS `DAYPLATE_SERVICE_URL` build setting to this service’s public HTTPS URL before shipping the app. That URL is configuration only; it is not a credential.

## Cloudflare Workers

The service is configured for Workers. There is no build command: it is plain JavaScript. From this directory, use `npm run dev` for local Workers development and `npm run deploy` to deploy. The deploy command is `npx wrangler deploy`; Cloudflare reads `wrangler.jsonc` in this folder, so configure `catalog-service` as the working directory in Cloudflare Workers Builds or GitHub Actions.

For local Workers secrets, create a non-committed `.dev.vars` file with the same four variable names. In Cloudflare, add those values as Worker Secrets—not plaintext Variables—before deploying. `dayplate-food-api` is the default Worker name and can be changed in `wrangler.jsonc` before the first deployment.

Ingestion groups deterministic exact keys first. `duplicateCandidates` creates only plausible later-stage candidates. An agent may return the documented structured merge/keep decision, but `applyAgentDecision` accepts an automatic merge only at high confidence when normalized identity, serving weight, and key nutrients agree. Conflicts remain separate for review, while all original records and import timestamps remain in `sourceRecords` for auditability.

## Curating exact branded menu products

Run tools/curate_menu_products.py to build a review-ready JSON catalog for one brand at a time. It asks for the brand and any official or trusted links that should guide its research, then uses OpenAI web search to find source-linked nutrition facts. It deliberately records whole purchasable products rather than breaking a named product into ingredients.

Set OPENAI_API_KEY in your shell, then run:

    cd catalog-service
    python3 tools/curate_menu_products.py

It defaults to gpt-5.6-luna with high reasoning for research, then independently checks every result with gpt-5.6-sol at xhigh reasoning before writing the JSON. Use --reasoning xhigh for a deeper research pass, --review-model to select another verifier, or --max-products 50 when you want a larger batch. The JSON is written to the directory from which you run the command, never overwriting an existing default-named file. Review each output before copying records into src/menuProducts.js; the generated schema keeps unknown optional nutrients as null instead of treating them as zero.
