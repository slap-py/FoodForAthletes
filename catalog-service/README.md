# Dayplate catalog service

This service exposes `GET /v1/catalog`, `GET /v1/foods/search?q=…`, `GET /v1/foods/:id`, and `POST /v1/meal-analysis`.

`GET /v1/foods/search` queries FatSecret first and then appends USDA FoodData Central results. It deliberately does not deduplicate results. `POST /v1/meal-analysis` sends the user’s text to FatSecret NLP, then provides that returned reference data, the original text, and the optional meal and nutrition-label images together in the OpenAI Responses API request. It does not call FatSecret barcode, autocomplete, image-recognition, or recipe APIs.

## Configuration

Copy [`.env.example`](.env.example) into your deployment’s secret manager and set `FATSECRET_CLIENT_ID`, `FATSECRET_CLIENT_SECRET`, `USDA_FOODDATA_API_KEY`, and `OPENAI_API_KEY`. Never place these values in the iOS app or source control. FatSecret's OAuth client-credentials flow requires the token request to come from a proxy service, which is why this service owns the credentials and caches its access token.

Set the iOS `DAYPLATE_SERVICE_URL` build setting to this service’s public HTTPS URL before shipping the app. That URL is configuration only; it is not a credential.

## Cloudflare Workers

The service is configured for Workers. There is no build command: it is plain JavaScript. From this directory, use `npm run dev` for local Workers development and `npm run deploy` to deploy. The deploy command is `npx wrangler deploy`; Cloudflare reads `wrangler.jsonc` in this folder, so configure `catalog-service` as the working directory in Cloudflare Workers Builds or GitHub Actions.

For local Workers secrets, create a non-committed `.dev.vars` file with the same four variable names. In Cloudflare, add those values as Worker Secrets—not plaintext Variables—before deploying. `dayplate-food-api` is the default Worker name and can be changed in `wrangler.jsonc` before the first deployment.

Ingestion groups deterministic exact keys first. `duplicateCandidates` creates only plausible later-stage candidates. An agent may return the documented structured merge/keep decision, but `applyAgentDecision` accepts an automatic merge only at high confidence when normalized identity, serving weight, and key nutrients agree. Conflicts remain separate for review, while all original records and import timestamps remain in `sourceRecords` for auditability.
