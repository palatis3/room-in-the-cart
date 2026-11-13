# Two-shard owned simulator pilot

The next normal CI candidate creates a fresh simulator only for Core `ui-01` and fixture `contributor-balanced-01`. Every other shard retains the existing selection policy. The pilot preserves the selected device type and exact runtime identity; it does not switch operating systems, retry failed setup, or fall back to an image device.

This is an isolation experiment, not a demonstrated repair for either current hosted failure. At published head `14ac1e39021eaa2047e21bd3ac24328e6b36a068`, UI01 failed acquiring an app background assertion and contributor-balanced-01 stopped at a terminal simulator data migration failure before starting tests. Their causes remain unresolved.

## Verification

- Twelve ownership and workflow policy tests and seventeen workflow guard tests passed on the final pilot revision. The policy test executes the actual workflow Bash with inert command replacements, checking both exact opt-ins, ordinary shards, near-miss names and failure propagation without fallback.
- Actionlint and the fifteen-node queue policy passed. The unchanged boot guard and trigger coverage had previously passed twelve and six tests respectively.
- An actual local attempt selected iPhone Duo / iOS 27.1 build `24A94425` under the unchanged selection policy. Creation and ownership verification succeeded. The boot guard correctly rejected terminal `Data Migration Failed`; **no app tests ran**.
- Cleanup deleted only the newly created device. Comparison of the initial and final inventory showed all pre-existing device identities and states unchanged.

Local boot failure means healthy boot and execution on the hosted runtime remain unqualified. The local runtime also differs from the hosted runtime. The pilot must be assessed in the next normal CI cohort before expanding its scope.

## Boundaries and retained evidence

Creation receipts bind repository, run, attempt, job, shard, toolchain, nonce, device type and exact runtime build/bundle. Cleanup verifies ownership and current identity before shutdown or deletion, refuses source devices and mismatches, and records its outcome before artifact upload. Missing receipts cause no device mutation. Existing boot guards, test assertions and execution limits remain in place.

Private original evidence is retained under `.build/CI14AC1E3Nov08/owned-simulator-native-qualification/`. Its terminal `run.json` SHA-256 is `6728577d2fb42706224d63a6f3853e8f90fc61ff75b108d9cfa2a2a90c0fe203`. The final source/check receipt is `.build/CI14AC1E3Nov08/owned-simulator-pilot-source-receipt.json` (SHA-256 `8b283c21303db40f71c6e6756cb1c586152b2e7b573940641e4d5dc3faaf2310`). Neither this pilot nor the local quote correction was present in the active 14ac cohort.
