# Main branch protection verified

On November6 at20:20UTC, root enabled baseline protection for `palatis3/room-in-the-cart:main` and independently read it back. The branch previously had no protection and the repository had no rulesets.

A pull request must satisfy `CI gate`, `CodeQL (javascript-typescript)`, `CodeQL (actions)` and `Dependency review`, each bound to verified GitHub Actions app15368. The branch must be up to date, conversations resolved, and admins follow the same policy. Force pushes and deletion are disabled. No second human approval is mandatory for this single-owner repository, and the branch is not locked.

[Independent review](INDEPENDENT-REVIEW.md) · [Verified settings and unchanged references](verification.json) · [Exact applied request](main-protection-request.json) · [Independent API readback](independent-readback.json) · [Observed check providers](required-check-providers.json).

The initial compatibility request included both `checks` and empty `contexts`, following the public API documentation's required-field wording. The deployed API rejected that combination with422 and an overlapping-oneOf error. A read confirmed main was still unprotected. Root removed only the empty legacy `contexts` field, preserving all four app-bound checks, and the request succeeded. [Observed rejection](write-response.json) · [Correction](schema-correction.json). No policy was weakened to make the request succeed.

This is **core/security merge protection**, not approval to release. Path-filtered fixture/deep/performance/native-wire contexts are not directly required because skipped workflows would block documentation-only PRs. They remain mandatory in the unfiltered exact-candidate `Pre-release regression checks` workflow before distribution, alongside release metadata, full dependency audits and exact-commit CodeQL checks. Signing, live-provider, physical-device and human acceptance remain separate. The baseline can permit a merge while an extra path-filtered workflow is failed; it must not be described as all-regression enforcement.

No commit was pushed, no PR merged, no CI retry dispatched and no paid feature activated. Main remains1a2530a7ad006b5939f87a08a1964b5fc863383e; PR1 remains draft at804030e. Verification used configuration readback, not a deliberate forbidden push or merge.

Official references: [Branch-protection API](https://docs.github.com/en/rest/branches/branch-protection), [required-check behavior](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks), [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
