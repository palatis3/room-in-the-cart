# Private reports and sender blocks

The feature covers received household request wording, shopper clarification, cook projections, helper corrections and shared dated cook copies. The household service verifies the current authenticated device, household, granted projection or own-request scope, exact record revision, field and original sender. Private offline entries stay on the device. Existing grant expiry, consent withdrawal and revocation still apply.

The native and companion clients request the safety capability using `X-Shared-Content-Safety: 1`. Show safety actions when the service advertises `shared_content_safety`. A child can report a question on their own request. An invited cook can report a field in their current instruction, including in a read-only grant. An assigned shopper can report contributor wording, incoming suggestions or another shopper’s dated copy in their authorized shop.

## Household action

`POST /v1/households/{householdId}/moderation/actions` uses the existing authorized-device or session credentials. Browser mutations require the same origin and CSRF protections as other commands. Supply a new UUID `clientKey` for each reviewed action. Reuse it for an uncertain retry with precisely the same action, content reference, disclosure choice and scope.

| Field | Supported values |
| --- | --- |
| action | `report` or `block` |
| source | Opaque record UUID `id`, displayed positive integer `revision`, `kind`, `field` and, for an instruction row, zero-based `index` |
| reason | Required for a report. `harassment`, `unsafe` or `other` |
| text | Optional for a report. The user affirmatively selects the exact displayed field. An immutable dated copy supports an exact contiguous excerpt up to 1,000 characters. Blocks omit text. |
| response | `receiptId` and `status` (`received` or `blocked`). A receipt acknowledges the submitted action. |

| Source kind | Record and accepted fields |
| --- | --- |
| request | Request ID and revision, `item` or `amount`, visible to its assigned shopper |
| clarification | Request ID and revision, `question`, visible to its contributor |
| instruction | Recipient’s live grant ID and revision. `shopLabel` or an item’s `label`, `amount`, `unit` or `action` |
| suggestion | Proposal ID and proposal revision, `correction`, visible to its authorized reviewer |
| cookCopy | Dated copy ID and immutable version, `text`, visible to its assigned shopper |

Current scope or source loss returns the service’s unavailable result. Changed wording returns `stale_base` when the person still has access. A legacy message with unknown authorship remains reportable. Blocking it returns `sender_unavailable`. The service never substitutes the current shopper for an earlier sender. A personal block follows the sender within the household. Operator suspension follows the verified account across memberships. Underlying order quantities and financial history keep their meaning.

## Responding to a private report

Provision a separate individual database login belonging only to the NOLOGIN `ritc_moderator` group for a designated operator. Keep that credential in the operator’s managed secrets and outside the customer service, scheduled heartbeat and mobile application. Use a verified TLS connection under that login. No public moderation management endpoint exists. The application role has neither access to the operator queue nor permission to read case excerpts.

1. Check non-content queue age and expiry with `SELECT * FROM ritc.moderation_workload()`. Escalate aging cases against the staffed response timeline. Inspect the oldest 50 open reports with `SELECT * FROM ritc.moderation_queue()`. Each result contains a random case ID, time and expiry, selected field, reason, sender-known flag and the excerpt the reporter chose. A blank excerpt is an intentional privacy choice. The queue omits member names, reporter identity, email, household roster, budgets, full recipes and adjacent lines.
2. Bind the case UUID and reviewed decision as independent SQL parameters in `SELECT ritc.moderation_resolve($1,$2)`. Use `dismiss` to close a concern, `remove` to suppress the current wording and `suspend` to remove it and restrict the known author. A different resolution after adjudication is rejected. A repeated identical resolution is idempotent. The database records the time and individual login. There is no automatic sanction from the report count.
3. Verify the effect through the appropriate shopper, contributor or cook view. Test that an unrelated household cannot see the report and that the blocked wording stays absent after refresh. Offline copies shared outside the service remain under their recipient’s control.
4. Run `SELECT * FROM ritc.moderation_prune()` under operator authority on the approved recurring schedule and before opening any restored database to users. Escalate any nonzero `expired_unreviewed` count to the designated operator. Record only the run time and aggregate counts in routine operational logs. Evidence and reporter-linked receipts expire according to the reviewed deployment’s retention interval. Blocks and removal decisions persist to enforce the user or operator decision. Account erasure clears report and block links to the affected member.

## Activation and response ownership

Production defaults to disabled. Enabling it requires `SHARED_CONTENT_SAFETY_ENABLED=true`, a nonempty `MODERATION_OPERATOR_APPROVAL` reference and `MODERATION_RETENTION_DAYS` set to the approved positive interval of at most 365 days. Changing the retention interval affects newly accepted actions.

Before activation, Venture House Group LLC designates the staffed queue owner and backup, records the response and escalation timelines, approves access and retention including backups, verifies the public support inbox, and reviews disclosures for family and child data. Run a synthetic exercise from both languages on the scoped iPhone and browser clients. Verify a report with and without an excerpt, an organizer as the reported sender, an unknown legacy sender, a lost reply, a cross-household rejection, an actual resolution, expiry and account erasure. Confirm the monitoring schedule alerts an accountable operator before an unanswered case expires. Record completion against the build, service and migration in the release checklist.

The implementation does not assign Apple an enforcement deadline. Apple requires ongoing filtering, a way to report concerns, timely handling, blocking and published contact information. [Apple App Review Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)
