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
