# Dayplate catalog service

This reference service exposes `GET /v1/catalog`, `GET /v1/foods/search?q=…`, and `GET /v1/foods/:id` over a versioned canonical catalog. The checked-in records are a compact fixture; an importer can pass normalized USDA Foundation, FNDDS, and Branded records to `buildCatalog`.

Ingestion groups deterministic exact keys first. `duplicateCandidates` creates only plausible later-stage candidates. An agent may return the documented structured merge/keep decision, but `applyAgentDecision` accepts an automatic merge only at high confidence when normalized identity, serving weight, and key nutrients agree. Conflicts remain separate for review, while all original records and import timestamps remain in `sourceRecords` for auditability.
