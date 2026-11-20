# Requester choices and shared picking

Apply migration 070 before serving clients that use these routes. The two runtime switches are independent and default off. `TRIP_SUBSTITUTIONS_ENABLED=true` advertises `trip_substitutions`. `SHARED_PICKING_ENABLED=true` advertises `shared_picking`. Both use the existing shared-content moderation configuration. Clients discover either capability in the adult shop bootstrap. Existing clients can continue using their request and checkout screens.

All paths below are relative to `/v1/households/{householdId}/shops/{shopId}`. The existing live session, enrolled device and selected-shop checks apply. Scope is limited to draft and frozen trips. Selected helper and own-request-queue sessions cannot use these routes.

## Requester choices

`GET /requests/{id}/substitution` returns `requestId`, `originalItem`, `own`, `requestRevision`, `authorityEpoch`, `revision`, `choice` and nullable `alternative`. The current original adult request author and assigned shopper can read the decision. An unanswered request has choice `undecided`.

The author sends `POST` to the same path with `clientKey`, `expectedRevision`, `requestRevision`, `authorityEpoch` and `choice`. Allowed choices are `exact`, `alternative` and `skip`. Only `alternative` takes a named pack in the `alternative` string. A request wording or amount edit clears the answer. A status change from pending to added preserves it. Changing shopper, closing the trip, blocking or losing participation ends its scope.

An unanswered request permits the original label on an add, link or linked-line edit. This also applies when an earlier answer was cleared. The original label is allowed for all three answers. An alternative must match the approved name exactly. Under `skip`, the shopper can mark the request handled if the original pack is unavailable. The existing preview and apply calls both check current permission. The preview fingerprint binds the current answer revision and the reviewed line and offer evidence. A later rename of a linked basket pack must also satisfy the current choice. The service uses the names the adults reviewed. It does not infer retailer SKU equivalence from those names.

Report or block shared alternative text with the existing household moderation action, using source `{kind:"substitution",id:requestId,revision,field:"alternative"}`. The original item uses the existing request source.

## Shared picking

`GET /shared-picking` returns the following fields.

| Field | Contents |
| --- | --- |
| `managed`, `authorityEpoch`, `shopRevision` | The caller's role in this trip and the versions for management changes |
| `permissionId`, `recipientId`, `expiresAt` | The live permission, its recipient and its ISO expiry, all nullable for the shopper |
| `members`, `availableRows` | Eligible adults with `id,label` and household basket candidates with `id,label,packs`. These arrays are empty for the recipient. |
| `rows` | Explicitly shared rows with `id,safetyId,label,packs,picked,revision,claimedBy,claimedByLabel,lastActorLabel,undoOperationId` |

The assigned shopper posts `/shared-picking/permission` with `clientKey,expectedPermissionId,authorityEpoch,shopRevision,recipientId,lineIds,expiresAt`. A new or replacement share selects one other contributing adult, 1–200 distinct household basket rows and an expiry within 24 hours. Each replacement gets a new permission ID. Revocation sends the current permission ID, null recipient and expiry, and an empty list. The response is the current page. Private local rows and request-linked wording are ineligible.

Either participant posts `/shared-picking/operations` with `operationId,permissionId,actorId,deviceId,rowId,expectedRevision,action`. A `claim` takes an unclaimed row. A `pick` also takes a positive integer `packs`, at most the current remaining quantity. An `undo` names the caller's latest undoable operation in `undoOperationId`. A claim held by one participant prevents the other from picking it. Partial picks preserve the remaining packs. Completion clears the claim.

A successful operation returns `operationId,rowId,revision,picked,safetyId`. Store the original intent in the enrolled device's authorized scope. Reuse its ID and body after an uncertain response. The service checks the live actor, device, household, permission, row and publication before reading any receipt. Concurrent last-pack changes serialize under the existing household transaction. A matching retry returns the original receipt even after subsequent changes. A new stale operation receives 409 `stale_base` and needs a refreshed row. A changed payload with the same ID receives 409 `key_reused`. A revoked or expired permission receives 404 `unavailable`, and revoked enrollment receives 403 `access_ended`.

A changed basket quantity withdraws the row until the shopper shares it again. Accepted counts for the same pack survive, including when permissions change. A replacement product starts a new row publication. A published label supports the existing report and block action with source `{kind:"pickingRow",id:safetyId,revision:1,field:"label"}`. Picking only records progress. Freezing and placing the order continue to require the assigned shopper.

## Two-simulator development fixture

From the repository root with the pinned Node version and PostgreSQL 17 command-line tools on PATH, run the following commands.

```sh
npm --prefix service ci --ignore-scripts
npm --prefix service run build
node service/scripts/trip-simulator.mjs
```

The helper creates a fresh local database, enrolls Mia and Alex, and seeds an unanswered oat milk request and two basket rows. It listens on the Mac's loopback interface. The simulator's debug actor selector reads `/fixture/shopper` or `/fixture/requester` on port 48761. Their signed requests use the standard API on port 48762. Accounts expire after four hours. Press Ctrl-C to stop the service and remove its temporary database. Restart for a fresh household.
