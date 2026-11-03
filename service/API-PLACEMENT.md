# B03 shopper-reported placement

These local-only APIs expose the existing immutable `shop_snapshot` and `placement_report` records. No migration or retailer integration is introduced. A report is a shopper's dated evidence, not provider confirmation or a charge. Existing `shop.reportPlaced` and `shop.reconcileReport` commands remain the sole mutation paths.

All routes below are under `/v1/households/{householdId}` and require a live provider session, active membership and the enrolled device. Helpers and children cannot use them. Reads are `no-store`.

| Method and path | Scope and result |
| --- | --- |
| `GET /shops/{shopId}/placement-reports/current-shop` | Current assigned adult shopper; existing `ShopperShop` projection. |
| `GET /shops/{shopId}/placement-reports?cursor={reportId}` | Current assigned adult shopper; at most **5** pending reports, each with its immutable original snapshot. |
| `GET /shops/{shopId}/placement-reports/{reportId}` | Current assigned adult shopper; one report including applied/rejected state, plus current review base. |
| `GET /shops/{shopId}/placement-reports/mine/{clientKey}?commandDigest={sha256}` | Original adult reporter and original enrolled device; `{status:null}` if their key has no report, otherwise a minimal current status. No basket, current authority, funding or current budget fields. |

The list response is `{shopId,shopRevision,authorityEpoch,phase,frozenRevision,reports,nextCursor}`. The detail response replaces `reports,nextCursor` with `report`. Each report contains:

```
reportId, shopId, reportedRevision, reportedAuthorityEpoch,
occurredAt, receivedAt, source: "shopper_reported", state,
snapshot, snapshotCreatedAt, snapshotDigest,
resolutionOperationId, resolutionClientKey
```

`state` is `pending_reconciliation`, `applied` or `rejected`. `snapshot` is the immutable original `{shopId,revision,phase,quote,lines,budget,mealRefs?}`; no current reporter profile is joined. `resolutionClientKey` is present only when the caller authored the resolving operation; otherwise null. Pagination orders by exact PostgreSQL `(received_at,report_id)`, and a cursor must belong to the same authorized shop. Five snapshots per page keep the bounded native response below its transport cap.

The reporter's status contains only `{clientKey,operationId,reportId,shopId,reportedRevision,reportedAuthorityEpoch,occurredAt,receivedAt,source,state}`. The digest binds the exact original command, using the existing canonical server digest. A changed digest yields `409 key_reused`. Status reads do not issue or renew replay windows and do not mutate or recreate a report. They remain available after the original replay window expires, provided current session/member/device and historical shop authority remain valid. Missing or erased records never trigger an automatic replacement command.

Native reporting sends `X-Shop-ID` for the original captured shop, even if a different shop is currently selected; this does not change the selection. The HTTP adapter marks only validated placement commands and placement read routes for a narrow historical-shop fallback. A historical adult authority row permits reaching the route-specific check after transfer or closure. It grants no current-shopper access: reviewer reads and reconciliation commands still require the current assigned adult and return `404 unavailable` on role loss. Other shop APIs retain their existing authorization. Session/member/device revocation remains an authorization stop.

A prepared native capture records the reviewed shop snapshot, subject/member/device, one client key, replay window/expiry and capture time **before** leaving the app or going offline. The later explicit placement report is sealed locally with its entered `occurredAt`. Retry uses those exact bytes, original base revision/authority epoch, key and window. It never fetches a new basket or silently updates the date. The minimal immutable report receipt is `{operationId,kind:"shop.reportPlaced",reportId,disposition}`; disposition is `placed` or `pending_reconciliation`.

A current shopper separately reviews the original report against the current base. Applying requires the reported snapshot to match the current frozen revision; changed baskets produce `409 reconciliation_required`. Rejecting preserves the current basket. Review retries keep their original bytes; an expired/stale action is inspected through the exact report detail, not recreated from absence in a pending page.

Verification is local-only: host Swift transport/contract tests and isolated PostgreSQL HTTP tests cover exact concurrent report/review retries, transfer races, changed frozen baskets, scoped pagination, original reporter status after closure/expiry, role revocation and minimal payloads. A fixed command has the same digest in Swift and Node (`2c5085b9ab57695f68a2164a13508eb7b1a511f08aeaa6417a1fd357df7a1218`). No deployed endpoint or real retailer behavior is claimed.
