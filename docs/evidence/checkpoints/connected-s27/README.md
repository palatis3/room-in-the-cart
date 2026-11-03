# Connected two-store quotes restart checkpoint

Saved locally on 2026-11-03. The shipping local S27 screen already compares two entered quotes. The connected household version remains unfinished. No connected route, permission or migration from this checkpoint is installed.

## Saved work

`connected-s27-work-in-progress.tar.gz` contains the proposed PostgreSQL migration 018, a TypeScript service draft, and six comparison tests. Its SHA-256 is `f00bfb81ccb7195a2a116d16740a944e42884fd778b3d7da7d6d8be59c5edca8`. Extract it into a temporary directory, compare it with the current service tree, and confirm that migration number 018 is still available before resuming.

The full TypeScript service compiled with the draft in place. All six standalone calculation tests passed under the repository’s pinned Node 22.14.0. The cases distinguish merchandise from checkout and incremental trip cost, show a $3 break-even when second-trip cost is unknown, and withhold a winner for missing charges, unconfirmed availability, unmatched quantities and ties. See `quote-math-tests.log`. The database operations and native path have not been tested.

The draft models separate per-adult budget grants for the current shop and shopper authority epoch. It separates saving from proposing and shopper adoption, binds quotes to a reviewed revision, and records whether each option covers the same basket quantities. The shopper can see a grantee’s quote only after an explicit proposal. The proposed adoption uses the existing shopper patch transaction to clear prior line prices and charges. A separate adopted basis holds the selected branch, mode and slot. The recipient list is for the current shopper alone.

## Resume

1. Review the SQL and service draft. Test migrations 001–018 on an isolated PostgreSQL database. Exercise tenant isolation, adult and helper scopes, authority transfer, database rollbacks, concurrent retries, grant revocation and account erasure. Confirm old offers, request previews and freeze operations cannot use superseded prices. Audit schema cardinality and mutation receipt retention before wiring the service.
2. Wire scoped `/shops/{id}/store-quotes` reads and grant, save, propose and adopt writes in `service/src/http.ts`. Make selection and bootstrap discoverable to adults with that specific shop grant. Keep this Free manual permission independent of meal access, contributor status, household administration and paid seats. Preserve dated, read-only proof and prohibit new adoptions on non-draft shops.
3. Add the connected HouseholdClient contract and native household/S05 route. Reuse entered-store fields and match CoreDomain comparison results. Distinguish own private saves from submitted proposals and separate shopper review from final adoption. Verify $38/$35 checkout, $0/$4 trips, +18 minutes and missing travel in a real local service/native run. Test unknown/unavailable options, exact retries, stale revisions, frozen/placed shops, revocation and wrong-tenant access. Coordinate any shared view or project-generator edits with the integration lead.

No backend deployment, provider change, Apple account operation, database migration or simulator use occurred for connected S27. The SE was returned to the integration lead after S05.
