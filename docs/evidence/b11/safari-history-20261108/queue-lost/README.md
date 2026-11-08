# Safari retries a committed request after its reply is lost

The **queue-lost case passes** on the same owned iPhone17 Simulator/iOS26.2 MobileSafari. The fixture accepted one real product Send, recorded its effect and dropped the reply. Native Safari Reload retained the exact pending IndexedDB command and sent nothing automatically. One explicit Retry used the same actor/key/body digest/device grant, leaving **two POST attempts, one effect and one received row**. The pending copy was removed only after the retry's successful receipt.

This is actual Safari input, native Reload and IndexedDB against controlled synthetic authority. It does not establish live provider, real-service PostgreSQL, physical-device or radio-failure behavior.

## Three actual observations

1. On a fresh isolated origin, root opted into the actual queue permission, entered `SAFARI_QUEUE_OATS_4101`, reviewed it, selected the fixture's commit-then-drop mode, and tapped product Send once. Root observed waiting/pending. [Queued receipt](observation-queued.json): one stored command, one POST attempt, one effect, Retry present and a ready/non-busy view. The server records exactly one `command-after-effect-drop` event.
2. Root set the observation phase and used Safari's native Reload. The pending card **and already received row were both visible**. [Reloaded receipt](observation-reloaded.json): the same one stored command, still one attempt/effect, Retry present and empty top-level status. Reload did not send another command. The pending card represents unresolved client receipt recovery, not another server purchase or request.
3. Root tapped the actual product Retry once. Pending disappeared; the exact **Received by the shopper.** top-level notice and received marker row appeared. Root observed the received row's original time. [Final receipt](observation-final.json): two matching attempts, one effect/row, one exact-retry event, zero stored commands, no Retry, ready/non-busy state.

The probe's marker Boolean cannot count two rendered instances or inspect the row's displayed time. The intermediate dual representation and retained original time are root's visual observations in the Device Hub CUA transcript. No standalone PNG/video export is claimed. Server row/effect counts and stored command digests are separately verified facts.

Both stored copies and both actual POST attempts have SHA256 `2a172796034af370216630a1f65dabf0409cd75c724bd31f1d11840b18fdbf5c`; the recorded actor, client key and queue grant also match exactly. [Complete stopped receipt](receipt.json) preserves all three phases and bounded server events.

## Exact proof and cleanup

The unchanged frozen R2 verifier was rerun read-only and passed with **two attempts/one effect**. [Output](verification.stdout.txt), [verification and supplemental checks](verification.json). It also reverified the exact helper, copied-asset and root-reviewed build provenance pins. Manifest identity remains `bffa8e626fc1f2e5645864c38d0017ab215e19170aef59383c3d417cb6ddcb62`; [manifest](helper-provenance-manifest.json). Receipt SHA256: `4c0633c66a286cbca5255783a8ec19723a48c374c1b37973d30d025b4003ecc4`.

Exact [probe](probe.js), [observation schema](observation.mjs), [case verifier](verify-case.mjs) and [pin verifier](verify-pin.mjs) reference copies are bound in [copy provenance](copy-origins.json). The read-only verification used the complete frozen scratch package; these copies are not a standalone executable installation. The unchanged synthetic fixture preserves an operation's original receipt on exact replay and rejects changed bodies. No real-service authorization or provider claim is added.

Root reports exec24557/PID8055 stopped with terminal exit0. Independent read-only inspection of the owned port52060 returned ECONNREFUSED. [Prior-proof preservation](prior-proof-preservation.json) verifies all48 earlier evidence files remain unchanged. No browser, native app, listener, server control, product/helper edit, handoff edit, commit or push occurred while preparing this proof.

## Remaining limits

The [original runtime identity](../owned-simulator-safari.json) and instrumented fixture HTML limitations remain applicable; simctl build23C52 and the MobileSafari executable mount's `iOS_23C54` path are retained without normalization. This was actual Simulator Safari, not desktop WebKit. The current record qualifies four history cases plus offline-queue and lost-reply cases. **Queue eviction and permission revocation remain unexecuted.** No cold Safari process restart, device reboot, Spanish Safari, real-provider/physical/human task, full Safari matrix or complete first-version release is claimed.
