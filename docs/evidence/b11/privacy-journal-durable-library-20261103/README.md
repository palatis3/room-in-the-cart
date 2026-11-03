# Option A library candidate — ready for root review, not installed

The dedicated production-library candidate compiles and passes **89/89 focused tests**, with zero failures, cancellations or skips. Independent review ran a separate typecheck and the same actual adapter suite successfully. `git apply --check --whitespace=error-all` succeeds against the current repository. No live source, runtime availability, SQL, role, provider or deployment was changed.

Review the [exact five-file patch](option-a-library.patch), [hash manifest](MANIFEST.json), [actual results](evidence/actual-focused-result.json), and [independent review](review/INDEPENDENT-REVIEW.md). Patch SHA256 is `184592c1910cbf1b490787ba350b0923bd1030210176c27ab69e58be42966725`. The four copied build-baseline files still match live source; they are not included in the patch.

## Candidate files

- `service/src/privacy-journal-durable-contract.ts`: caller deadline/signal, fixed pins, immutable record transport, checkpoint authority, authenticated observations/receipts, persistent uncertainty guard, and private committed-source contracts.
- `service/src/privacy-journal-durable.ts`: trusted local signer, strict current semantic validation, signed canonical v1 records, public-only independent witness key, fresh authenticated head checks, exact retry/commit binding, pre-storage content checks, bounded append, and abort/deadline propagation.
- `service/tests/privacy-journal-durable.test.mjs`: real compiled-library tests.
- `service/tests/durable-independent-fixture.mjs` and `durable-authority-fixture.mjs`: independent in-memory test capabilities and real synthetic-key crypto; neither is a production backend.

The signer has no network endpoint, generic sign-JSON interface, ambient-environment setup, recovery/reset authority, runtime composition or default transport. Every capability is explicitly supplied at the private trusted constructor. Only the actual SQL-produced acceptance candidate may reach `beforeCommit`; all committed observations and progress authorization come through fixed-source lookups. New instance construction cannot clear the required shared uncertainty claim.

## Review findings fixed and verified

Review found and fixed private witness PEM being accepted through implicit public-key derivation, and historical intent retries missing a fresh active generation/head check. The initial authority-fence red run is retained separately. Strict progress validation was also strengthened to compare the original acceptance with its admitted receipt and exact signed object before storing any progress object. Normal empty acknowledgement/status reconciliation now verifies the genuine original accepted job without opening an unnecessary mutation claim.

Tests cover those cases plus wrong source/event/job identity, mutable caller inputs and pins, signed receipt/ticket tampering, nonce replay, canonical bytes and storage versions, exact retry after later heads, lost-response persistent uncertainty across recreated adapter instances, generation/fence refusal, append limits, automatic deadline abort, late ignored completion not starting the next side effect, and safe completion of an acknowledgement already sent before abort.

## Required integration work remains separate

[SHARED-HOOKS.md](proposals/SHARED-HOOKS.md) proposes the necessary caller context/pre-COMMIT check and bounded private-source observation/receipt-checked acknowledgement boundary. It separately describes optional shared envelope-parser reuse to reduce schema duplication. Existing gate order, status-capability validation, cleanup-only maintenance and unavailable default deletion runtime remain unchanged. No existing service/runtime/SQL file is in the patch.

Real immutable storage, authenticated checkpoint/uncertainty services and the private SQL source adapter are **not supplied**. Their atomicity, durability, independent credentials, cancellation and latency must be proved separately. This library sends a real owned AbortSignal to every injected phase and prevents its own late continuation; it cannot make a transport that ignores cancellation cancel actual I/O. A source adapter must recheck after connection acquisition and immediately before SQL dispatch. Existing approved safe late acknowledgement behavior is retained, not replaced by a new timeout-eligibility policy.

The 89-case proof exercises actual compiled library code, Ed25519 validation and real AbortSignal/deadline behavior against **synthetic injected backing capabilities**. It is not an HTTP/fetch/PostgreSQL integration test, physical process restart, provider durability test, or operator recovery/export/seal proof. The earlier 30-case prototype remains separate synthetic design evidence. Real remote durability remains open.

## Reproduce without installation or downloads

From this scratch directory, using the existing pinned local tools/dependencies:

```sh
'/Users/palatis/Room in the Cart/.tools/node-v22.14.0-darwin-arm64/bin/node' service/node_modules/typescript/bin/tsc -p service/tsconfig.json
'/Users/palatis/Room in the Cart/.tools/node-v22.14.0-darwin-arm64/bin/node' --test service/tests/privacy-journal-durable.test.mjs
```

`service/node_modules` reuses the existing repository dependency tree. Fresh test signing keys stay in memory and are not exported. All test processes finished. Root owns review and any subsequent local installation, staging or commit; no activation is implied by installation of unused library files.
