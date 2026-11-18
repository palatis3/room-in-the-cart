# Reviewing a request against a meal need or recorded purchase

Migration 060 adds the references and replay state for this shopper decision. Apply it before serving a build that advertises `request_same_item`. Existing requests, accepted links, sealed orders and history require no conversion. Older native clients continue to read the ordinary request statuses and ignore the additional shopper-row field. An updated client needs the capability before it can select or undo a match.

The assigned shopper sends the ordinary shop preview with the pending or clarified request ID, its revision, the shop revision and authority epoch. The decision can identify either source.

```json
{"choice":"sameItem","target":{"kind":"meal","factId":"<tracking fact UUID>","factRevision":1}}
```

```json
{"choice":"sameItem","target":{"kind":"purchase","sourceRequestId":"<other request UUID>","sourceRequestRevision":4,"lineId":"<placed line UUID>","placedRevision":6}}
```

For a draft meal the service reads the current tracking catalog, including unbound ingredients and meal-origin reservations. For a placed or closed shop it verifies the separate added request, its current bought receipt and its original link in the exact sealed snapshot. The source and selected request must belong to the current shop. Their item wording must match after canonical Unicode, case and whitespace normalization. An explicit target ID distinguishes two matching names. A differently worded meal discovered through an existing basket link can still be reviewed with the ordinary basket-link action.

The preview includes the selected target's original item, amount or use, source label and exclusions. A protected meal adds its reservation purpose. A purchase adds the sealed line description and pack count. The shopper can compare these with the selected request before applying the existing `request.apply` command. Additional packs continue to use the regular add, budget and food review.

Application rechecks the exact source, retained evidence, request and shop versions, actor scope and original request-author consent. Only the selected request becomes handled. The other author's status, basket packs, purchase evidence, inventory, meal and protected commitments retain their values. Contributors see their own ordinary status. The shopper inbox includes `sameItemOperationId` only for a current match.

To undo, send a new ordinary preview with `{"choice":"undoSameItem","operationId":"<match operation UUID>"}` and apply its preview. This restores the prior pending or clarified status. A sealed shop routes the reopened request to the next shop. A changed selected-request revision prevents an older match from overwriting a later decision. Exact retries use the original envelope and replay identity.

A later meal revision or corrected source purchase invalidates the old proof and reopens the dependent request when the match still owns its current revision. Historical source revisions remain private until their normal erasure. Erasure of a referenced meal revision, purchase observation or decision preview removes its match and replay material, and restores the remaining author's applicable request. Reopened requests can receive a fresh independent decision from the inbox.

## Reviewing two open requests

Migration 061 adds the separate shopper capability `request_pair_review`. A client can offer “Same item” and “Additional quantity” for two distinct, current pending or clarified requests in the same draft shop. Both request authors must still have access, and the original item names must match after Unicode normalization, whitespace folding and case folding. An author may have written both requests. Request IDs distinguish two requests even when their authors have the same display name. The flow needs no meal, purchase or basket line.

Use the existing preview endpoint with the selected request’s normal base. Send one of these decisions.

```json
{"choice":"reviewRequestPair","otherRequestId":"<request UUID>","otherRequestRevision":1,"relationship":"sameItem"}
{"choice":"reviewRequestPair","otherRequestId":"<request UUID>","otherRequestRevision":1,"relationship":"additionalQuantity"}
{"choice":"undoRequestPair","operationId":"<pair operation UUID>"}
```

Each preview includes `requestPairEvidence` with the other request’s ID, revision, original item, nullable quantity, author alias and reviewed relationship. The checkout before and after is identical, and both purchase acceptance flags are false. Apply through `request.apply`. Its receipt carries the selected request’s original disposition and revision. Both authors keep their original wording, quantities, open statuses and ability to edit or withdraw. A shopper who wants to buy additional packs later uses the existing purchase and budget review.

Each shopper inbox row with a current relationship contains a `requestPairs` array with `otherRequestId`, `otherRequestRevision`, `relationship` and `operationId`. Own-request projections omit this field. Either side may start Undo. Relationships concern just the selected two IDs. A later edit retires its affected pairs and a withdrawal or erasure removes the private preview and response material. Exact retries recheck current authority and both source authors. A client connected to a server without `request_pair_review` leaves the two requests separate.
