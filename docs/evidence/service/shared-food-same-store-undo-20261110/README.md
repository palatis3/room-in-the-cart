# Same-store complete Undo — backend qualification

Ordinary food and existing-meal edits after a reviewed store selection can be undone while retaining that exact selection. The candidate binds immutable selection history and current authorization; revoked or erased evidence denies fresh Apply and retained inverse replay. Actual store-switch reversal remains separate.

Fresh strict TypeScript compilation and the full backend rosters pass: **653 offline + 1 expected skip**, **320 PostgreSQL + 3 existing optional browser skips**. This includes three new pure and five new HTTP cases, plus all prior meal/Undo/Records cases. Cancel, later unrelated work, exact retry, a held preview followed by permission revocation, selected-author erasure and placement snapshot compatibility are covered.

[Verification](backend-verification.json) records hashes of preserved originals under `.build/SharedDemandGraphNov09/root-same-store-undo-r1`. All 251 inputs, dependencies, tools and compiled products remained stable; the original journal fixture fenced and private PostgreSQL stopped. No private database archive is committed.

Native package/model/UI and actual Swift/HTTPS wire qualification remain pending. The subsequent wire-only test extension changes three service test/runner files; it does not change the qualified production compiler inputs. No staging migration/deployment occurred, and this result does not establish full release acceptance.

## Real typed-client qualification

The full successor passes all **15 Node cases and 45 Swift scenarios**, with no failures or skips. It includes Cancel, lost reply, persisted exact retry in a new process, selected-option author erasure, and permission revocation between preview and Apply. All 335 executed inputs and verified backend products remained unchanged; PostgreSQL stopped and successful private state was removed. The first failed attempt remains preserved. [Wire proof](native-wire-verification.json). This does not replace mixed-device UI or production-provider acceptance.
