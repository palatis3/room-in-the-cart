# Earlier workflow failure checks — November 9, 2026

Swift parsing now runs before the main app, fixture, StoreKit, performance and
package compilation lanes without adding runner jobs. Local `--changed` selection
includes staged, unstaged and untracked source while excluding ignored/deleted
files and package manifests. Release and Debug fixture parsing are bounded and
fail closed. The original missing-bracket fixture fails in 1.52 seconds; the
fixed fixture passes. The failed app build reported that error after 56.57 seconds.
These are observations for this case, not a universal speed guarantee. All 469
selected files parse in 7.35 seconds; compilation and original tests remain required.

The integration harness rejects invalid local URLs, missing/restricted fixture
roles, failed or mismatched actual connections, and existing single-use journal
origins before setup mutations or test fan-out. Every connection/query is bounded.
It supplies no credentials, changes no permissions and preserves the final journal
provisioning guard. Fresh databases still need the documented CI fixture roles.

The runbook requires a small owned collector control with observed readiness,
readable finalized output and expected events before another full-app performance
diagnostic. CLI support alone does not qualify capture. The latest capture remains
failed; this workflow change does not resolve its cause or approve a baseline.

Validation: 109 Python checks, 18 harness checks, six real PostgreSQL checks and a
real admin-login negative check pass. Actionlint and all 17 queue-node contracts
pass. No new full hosted batch or deployment. Full combined app qualification
remains separate. Exact source hashes and retained evidence: [verification](verification.json).
