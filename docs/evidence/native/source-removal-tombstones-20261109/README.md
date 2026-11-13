# Preserve earlier deletion history when removing a dinner

Removing one linked dinner previously changed the deletion dates of three unrelated,
already removed grocery rows. `ShoppingLedger.removeSources` now timestamps only
rows that do not already have a tombstone. The new model regression checks complete
row identity/history, surviving manual groceries, the other dinner, protected lunch,
allocations, revision and a Codable round trip.

## Verification

- Original implementation: the new regression fails exactly once on the unrelated
  dates; no compiler warnings. This is expected negative-control evidence.
- Fixed implementation: all **196 CoreDomain tests pass**, native exit 0; no compiler
  warnings. Canonical package and shared inputs match the verified 45-input manifest.
- The first full-suite preparation omitted two external shared JSON fixtures and
  failed two existing fixture-loading tests. It is retained. Adding those exact
  inputs and running the unchanged compiled suite passed; compiled products match
  the preserved build. No assertion or test was removed.
- Existing package CI automatically includes the regression; no extra runner/job.

This verifies model behavior. The actual iPhone removal journey and persisted
SQLite comparison remain separate pending acceptance, as does combined hosted CI.

## Original evidence custody

Retained locally under `.build/SourceRemovalAcceptanceNov09/model/`:

| Artifact | SHA-256 |
| --- | --- |
| `negative-source.json` | `fe942c8181726c096e6767605d9d79ed5ac35658b223ce7d10919830e7fc0228` |
| `negative/native.log` | `412a4981fbafeadb382feae932e5518ef2fa59e6d19a12a131a67fd1ab03ab42` |
| `fixed-source-complete.json` | `0f6ced9125af985a3759609e99b2e1b3dbc7eae95b1de962160b6d0532e30ac9` |
| `full-corrected/run.json` | `60fd10f62e78d6289afb831621c1f7afd1b2ac4b0d603ee34b73a3e4e5b0481d` |
| `full-corrected/native.log` | `adee29501b9b5c84d385c1160daf4ec9d6d5541bde0d59af71aad4a96f51ec89` |
| `full-corrected/verification.json` | `507a60bdf0486d5c715745e46670bd9c293cab915e4a3822eae6cd968422cd48` |

`installation.json` binds installed files to that source. Raw logs, build products,
failed preparation and original negative control remain local, not duplicated in
Git. These local paths are not public hosted evidence or a remote backup.
