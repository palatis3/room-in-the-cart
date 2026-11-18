# Optional private Tonight explanations

`GET/POST /v1/households/:household/language-assistance/meal-explanations` uses the existing adult-only M1 authority, bounded transport, consent, request identity, shared quota/cost reservations and kill switch. No provider is enabled or funded by this route.

The version-1 POST extends the common language request with `candidates: [{id, allowedReasons}]`. The 1–8 selected source lines are the exact same candidate UUID/title set. Allowed reason codes are `pantry_match`, `ingredients_covered`, `needs_more_food`, `reviewed_preparation_time`. Titles are reviewed before explicit Send, subject to the common 512-byte line and 16-KiB request limits. Ingredient names, physical counts, prices, full recipes and the preference profile are not sent.

The strict reply is `{version:1, requestID, suggestions:[{sourceLineID,reasons}]}`. Unknown or duplicate IDs, repeated/unsupported codes, extra properties, invented prose, quantities or prices fail closed. Private candidate facts are client-reviewed projections, not server pantry records or shared mutation authority. The native app compares the exact current authorized recipe/pantry/profile/ledger/source/match projection before send, after response and before opening the existing Choose preview. No result persists or changes stock. Cost and missing quantities are rendered by existing deterministic app code. Final persistence still uses the ordinary private choice review and commit boundary.

Local matches remain usable without a provider, network or signed-in account. Provider failure leaves them intact. Explicit retries retain the same request identity; server admission limits may reject an already-admitted retry rather than silently charge again. Dismissal/lock cancels the response and clears displayed proposals. No claim of provider zero retention is made.

Offline tests cover English/Spanish, strict output validation, eligible-ID binding, private authority before/after the mocked provider and no automatic dinner/stock mutation. Native UI/runtime qualification and live provider quality evaluation are separate; this does not claim live activation.
