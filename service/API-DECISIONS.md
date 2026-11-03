# Family decision history

P07 records a completed, human-entered approval, exclusion or preference. A shopper may leave the observed outcome unknown, then enter or correct it after checking what actually happened. An approval alone supplies no evidence of delivery, a substitution, a charge or a retailer action.

## Requests

All paths below are relative to `/v1/households/{householdId}`. Use the existing authenticated household session and device. A selected-shop context (`X-Shop-ID` for native clients) further narrows every request. Only the currently assigned adult shopper of a non-retired shop may act on its records, including records made before a shopper transfer or shop closure. A selected helper grant, another household's identifier and organizer status alone grant no access.

| Method and path | Body or query | Access |
| --- | --- | --- |
| `POST /shops/{shopId}/decisions` | Create body below | Free |
| `GET /shops/{shopId}/decisions/{id}` | None | Free |
| `POST /shops/{shopId}/decisions/{id}/outcome` | `{"clientKey":"<uuid>","baseVersion":1,"outcome":"Delivered as requested"}` | Free |
| `POST /shops/{shopId}/decisions/{id}/promote` | `{"clientKey":"<uuid>","baseVersion":2}` | Active named seat |
| `GET /decisions` | Optional `shopId`, `product`, `dish`, `occasion`, `cursor` | Active named seat |

The creation key doubles as the record ID. Clients can save the shop ID and record ID to reopen a particular record on Free. Send all three context keys and the outcome key explicitly, using JSON null for unknown values.

```json
{
  "clientKey": "ce4556eb-e670-4afc-8ad5-9c6e13348d6c",
  "kind": "preference",
  "product": "Black beans",
  "dish": "Tacos",
  "occasion": null,
  "decision": "Choose the unsalted beans for this shop",
  "outcome": null
}
```

Allowed kinds are `approval`, `exclusion` and `preference`. At least one of product, dish and occasion must contain text. Each context field and search term accepts up to 120 UTF-16 code units. Decision and observed outcome text each accept up to 500. Text is preserved as entered. Empty or whitespace-only text, NUL, unpaired surrogates and additional JSON fields are rejected.

## Responses and concurrency

All five routes return HTTP 200 on success. The four shop routes return the record directly.

```json
{
  "id": "ce4556eb-e670-4afc-8ad5-9c6e13348d6c",
  "shopId": "d7d7081f-a3a8-4155-bb96-679f27f513d3",
  "version": 1,
  "kind": "preference",
  "product": "Black beans",
  "dish": "Tacos",
  "occasion": null,
  "decision": "Choose the unsalted beans for this shop",
  "outcome": null,
  "scope": "one_shop",
  "recordedAt": "2026-11-03T12:30:00.000Z",
  "observedAt": null,
  "promotedAt": null
}
```

Search returns `{"decisions":[…],"nextCursor":null}`, or a UUID cursor for the next page. Each call returns at most 50 records, newest recorded time first, with descending UUID order for ties. Reuse the same filters and selected shop on each page. The service checks each cursor against current authority and all supplied filters. Search combines the literal case-insensitive substring filters with AND. Percent signs and underscores are literal characters. Unsupported, duplicate and empty parameters are rejected. The response contains only currently accessible records.

A create starts at version 1. Changing an explicitly observed outcome or promoting a preference increments its version. Recording a new outcome requires a nonblank observation. Only an explicit promotion on a one-shop preference changes its scope to `lasting`. It may be promoted with an unknown outcome. A lasting preference remains a record for human review. Purchases, items, meal plans and shop revisions are untouched.

Retry the same mutation with its original UUID and body. After fresh authority and any required paid-seat check, an exact retry returns the original response, including its version. Reusing a key with changed intent returns HTTP 409 `key_reused`. A new action with a stale version, an unchanged outcome, an inapplicable promotion or an erased receipt returns HTTP 409 `decision_changed`. Reopen the exact record before forming a new intent. A paid lapse blocks search and promotion while current authorized shoppers retain Free recording and exact-record reads. Unauthorized shops, records and cursors return the ordinary unavailable response. Normal session, input and billing errors follow the existing household API.

## Erasure and verification

Migration 015 joins the existing household erasure hook. Erasing an author removes their records and all associated receipts. Erasing a later observer or promoter removes that member's surviving contributions and invalidates cached receipts containing those contributions, even if an observation has since been corrected. A remaining author's independent evidence is preserved. The runtime role cannot invoke the erasure hook. Both new tables require tenant row-level security.

Local verification on November 3, 2026 passed all seven P07 tests and all 91 combined PostgreSQL integration tests with the optional browser wire enabled. Both runs had zero skips. Logs are retained under `.build/p07-focused.log` and `.build/p07-database.log` at the repository root.

The dedicated suite is `service/tests/decision-history.integration.mjs`. It exercises the HTTP server with a real PostgreSQL runtime role, local signed identity fixtures, and a fictional billing gateway. No external account, retailer or Apple service is required.
