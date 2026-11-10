# Existing-meal operation Undo: proposed additive contract

Frozen native handoff for this scratch slice. Existing non-meal Undo response shapes and schemaVersion 1 remain unchanged. A response with scope.mealsChanged=false MUST omit mealUndo and action.body.mealEdit; explicit null is invalid. A meal candidate has scope.mealsChanged=true, MUST include the following nonnull mealUndo object and nonnull action.body.mealEdit, and still has scope.requestsChanged=false. A preview has the same relationship through operationUndo.scope.mealsChanged. No new client inverse request fields are accepted.

```
mealUndo: {
  occurrenceId: UUID,
  targetBefore: {revision: positiveInt, meal: SharedMeal},
  targetAfter: {revision: positiveInt, meal: SharedMeal | null},
  current: {revision: positiveInt, meal: SharedMeal | null},
  restoredMeal: SharedMeal,
  touchedFields: ["membership" | "title" | "day" | "kind" | "portions" | "protected" | "planning"],
  proposal: null | {kind: "change" | "move", proposalId: UUID}
}
action: {kind: "shop.patch", body: {
  lines: BasketLine[], quote: Quote,
  mealEdit: {occurrenceId: UUID, baseMealRevision: positiveInt | null, meal: SharedMeal}
}}
```

All keys shown in mealUndo and its nested values are required, even nullable keys. No proposalId/changeProposalId is present in action.body.mealEdit: this is a fresh shopper-authorized compensation, never replay or reopening of a consumed proposal. Creating a new occurrence, first adoption, request acceptance, store inverse and inverse-of-inverse remain unsupported. Historical meal operations without this new acceptance-time lineage remain unavailable; there is no backfill.

The target existed before the operation. targetBefore.revision <= scope.baseShopRevision; targetAfter.revision == scope.resultShopRevision. current.revision is the latest persisted revision including null tombstones, between targetAfter.revision and base.shopRevision inclusive. All three facts refer to the same occurrenceId. The new occurrence revision after Apply is base.shopRevision + 1, not an old revision number.

For a removed target, targetAfter.meal and current.meal are both explicitly null, current.revision must equal targetAfter.revision, touchedFields is exactly ["membership"], and restoredMeal exactly equals targetBefore.meal. A later recreation/removal conflicts even though the active shop list again shows absence. mealEdit.baseMealRevision is null only in this removal restoration case.

For an edited/moved target, targetAfter.meal/current.meal are nonnull and touchedFields is the unique nonempty changed top-level field list in order title,day,kind,portions,protected,planning. The planning object (groups, bindings, exclusions, quantities, deadline and evidence) is one atomic basis. Each touched current field equals the accepted targetAfter field; restoredMeal changes only those fields back to targetBefore. Other current fields remain exact. Current active occurrence facts and revision must equal the corresponding shop.meals entry. mealEdit.baseMealRevision equals current.revision. The mealEdit occurrence and meal must equal mealUndo occurrenceId/restoredMeal.

Candidate and preview bind the same mealUndo exactly. The effect digest includes mealUndo as well as the existing complete operation basis. Do not normalize or infer historical literals, quantities, conversions or dates in the client. Revalidate meal schema/protected rules and graph/source/pack conservation. A meal-only date/title change may legitimately have no touched lines, unchanged quote, and zero graph rows. Each resulting basket line still requires explicit current usable-pack/unknown acknowledgment before preview.

The candidate/read remains write-free. Apply uses the original PendingOperation/preview-reserved operation ID/outbox, with the ENTIRE returned action.body including mealEdit plus demandReview; omitting mealEdit is invalid. Cancel sends no command. Exact retry returns one original receipt but rechecks current authorization and retained historical meal/proposal lineage. All before/after/private meal data must clear on access loss, stale generation or redaction.

Additional unavailable reason codes: food_undo_meal_history_unavailable (missing, erased, drifted or revoked meal/proposal lineage), food_undo_meal_conflict (latest occurrence/touched state incompatible), food_undo_meal_protected (inverse reduces protected meal facts). food_undo_meal_creation_unsupported is defensive rejection of a null historical before value; new-meal creation normally retains food_undo_meal_action_unsupported because no existing-occurrence lineage is recorded. Existing codes remain valid. Old strict clients must fail closed on meal payloads; no compatibility claim is made for unmodified clients.

The content-free new lineage stores the original occurrence, exact before/accepted-result revisions and hashes, plus accepted proposal identity/type/hash when present. Existing shop snapshots bind only active mealRefs; they omit removal tombstone identity and do not hash meal bodies or bind which proposal was consumed. Recording those hashes at acceptance closes that gap without retaining extra private meal copies. Existing privacy erasure deletes the referenced facts, making lineage and replay unusable.
