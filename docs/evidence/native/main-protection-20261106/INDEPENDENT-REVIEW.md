# Final independent main-protection readback audit

**The successful checks-only request and independent GET readback match the intended baseline main-branch safeguard.** All 25 local comparisons passed. Applied request SHA-256: `7dbd589cb139a8c9c2ef60ac5138c73872bc023bce89948826a3b9d133855013`. This follow-up performed no remote operation or shared-source edit; it independently compared the retained request, failure, successful write and GET artifacts.

## Correction to the earlier review

My earlier advice to add `required_status_checks.contexts: []` alongside `checks` was wrong for the deployed API. It relied too literally on the documentation's “Required” annotation and should not have been treated as an established compatibility improvement. The live API rejected that combination with HTTP 422 because multiple oneOf alternatives matched (`write-response.json`). The immediate GET remained “Branch not protected” (`after-first-write-read.json`), so the rejected request did not establish protection.

Root removed only the empty contexts member. Local structural comparison confirms every check, app ID, strictness value and other setting is otherwise identical to `rejected-contexts-request.json`. The checks-only write succeeded, and its response body exactly equals `independent-readback.json`. The deployed API evidence controls this correction. The response's populated contexts array is a projection of the same app-bound checks; it does not justify sending both input alternatives.

The original review and proof are preserved verbatim as `INDEPENDENT-REVIEW.pre-api.historical.md` and `independent-review-proof.pre-api.historical.json`. They are historical and superseded on payload compatibility. The final `independent-review-proof.json` binds the accepted request/readback hashes and records all comparison results.

## Verified applied state

The retained GET addresses only `palatis3/room-in-the-cart/branches/main/protection` and shows exactly:

- Four required checks, each from GitHub Actions app 15368: CI gate, CodeQL (javascript-typescript), CodeQL (actions), Dependency review. No additional or omitted check and no app substitution.
- Strict/up-to-date status checks and administrator enforcement enabled.
- Pull-request review protection present, mandatory approval count 0, code-owner and last-push approval requirements disabled, stale-review dismissal enabled, and no returned bypass allowance.
- Conversation resolution required; force pushes and branch deletion disallowed; branch unlocked.
- Linear history and fork syncing disabled, no push restriction allowlist, no additional signature requirement or branch-creation block.

The recent successful CI gate and three security provider records remain evidence of the exact context/provider identities. The original workflow review remains applicable: ci.yml and security.yml have unfiltered PR triggers; CI gate checks every core dependency result, including skipped/cancelled/failing jobs, through its always-run aggregate. None of the path-filtered fixture/deep/performance/native-wire contexts is added, avoiding a new documentation-only path-filter deadlock. Existing failing/incomplete core checks still intentionally block merges, including administrators. Zero required human approvals avoids a mandatory second reviewer in this single-owner repository.

## Limits retained

This proves configuration and matching API readback, not behavior under a prohibited push or merge; no such action was used as a test. `verification.json` records main remaining 1a2530a and draft PR 1 remaining 804030e; this local audit did not independently refetch refs or PR metadata. It does not infer a merge, upload, source push, or test recovery.

The safeguard is still narrower than full release acceptance. Pre-release regression checks, all six scopes, whole-lockfile audit, exact-commit CodeQL/open-finding review, and owner/device/provider/signing requirements remain separate and incomplete. A baseline-eligible merge is not distribution approval. The successful protection change does not close the outstanding native failures or authorize release.
