# App Review walkthrough and fictional demo handoff

Prepared from native source on 2026-11-03. This is a reviewer script and release-owner handoff, not a completed review run. The repository has local native/service test evidence, but this document does not establish an Apple-distributed build, live email sign-in, production guardian verification or a successful sandbox purchase. Fill the build, device, locale, tester and result fields for the actual candidate; a source route is not evidence that it passed on that candidate.

## Review package supplied by the release owner

| Field | Required value |
| --- | --- |
| Submitted build/version and bundle | Record from the actual signed candidate |
| Operating support owner and public destination | Supply a monitored owner-controlled destination; do not use an invented email address |
| Privacy and terms pages | Supply operator-reviewed HTTPS URLs and both launch languages |
| Demo environment | State the exact isolated service environment; use fictional records only |
| Demo adult accounts | Provide two verified adults through App Store Connect's private review fields, outside this repository |
| Shopper and second adult | Identify the assigned shopper and a separate named planning seat |
| Contributor and cook | Provide the exact invitation/current-view review path, expiry and permitted scope |
| Guardian consent | Document the actual verified guardian path and revocation test; do not use real children |
| Apple product | Supply the actual product ID, storefront and reviewer purchase/restore instructions |
| Open gates | List unconfigured or failed behavior explicitly; exclude its claim from the listing |

Release metadata is wired through [the native configuration guide](../config/README.md). Blank URLs produce visible unavailable states. The current staging `/help`, `/privacy`, `/terms` and `/support` paths returned HTTP 404 on 2026-11-03 and must not be represented as published policies or support. The owner must finish the public pages, identity/email setup, signing and actual App Store configuration before a distribution submission that advertises those paths.

## Fictional local demo, no account required

Use a fresh isolated test installation. Do not erase a person's existing workspace to prepare a demo. Choose English or US Spanish in iPhone app-language settings and record the same route in each language. Keep item names and USD unchanged when switching language.

1. Open **Shop → Compare packs**. Use the fictional item **Demo wraps**, need **12 each**, pack A **8 each / $3.20**, pack B **6 each / $2.70**. Review two whole packs for either offer: A provides 16 for $6.40; B provides 12 for $5.40. Confirm that the screen describes an item-only comparison. Save it, quit and reopen it in **Records**. Clear one pack's usable amount and verify that its answer remains unresolved.
2. In **Shop → Start pickup** (or **Shopping list**), create a fictional pickup and type items. Review pasted/imported text before adding it; cancel a review and verify that the list stays unchanged. Enter a known cap and prices. Review checkout fees/taxes/discounts and an unknown cost. The whole-pickup result must preserve unresolved costs. A payment hold remains separate from spending.
3. In **Dinners**, save a simple fictional meal and review its portions and ingredient demand. Choose it for the current shop, then assign a night without creating a second occurrence. Review guests, an away night and a lunch reservation. Confirm pantry/freezer quantities explicitly before counting them. Preview and cancel a change, then verify the original plan.
4. From the shopping list, **Review checkout → Prepare retailer handoff**. Inspect the dated basket copy. Copy or share it to a controlled local destination; this does not place a retailer order. Report the fictional placement separately. Record actual usable quantities, then review a shortage and protect lunch reservations before selecting a repair. Keep any credit pending until an explicit posted event.
5. Open the saved pickup's **Tell the cook** route. Choose the recipient language, review the complete dated instruction and what remains unresolved, and share to a controlled destination. Report the recipient/version sent separately. A reported acknowledgment is a separate action. Never infer a retailer order, delivery or recipient read from share-sheet completion.
6. Open **Records → Recovery, exports and saved records**. Preview a narrow helper copy and a private owner export separately. Review an encrypted recovery file; include evidence photos only through the explicit selection/review path. Reopen a recovery file beside existing work and inspect conflicts before importing. Cancel deletion and verify persistence, then delete only the named fictional scope. Confirm that prior exported copies remain separate.
7. Open the **Settings** gear on a tab root. Read **Help**, **Privacy and data**, and **Support** offline. Verify the missing-policy/support states if metadata is blank. Inspect **Review support summary** before opening its system share sheet. The summary must contain only version/build/iOS/language/environment/configuration booleans; verify that it includes none of the demo food, prices, names, photos, identifiers, codes or links.
8. Open **Settings → Device shortcuts** with optional permissions denied and use typed paths. Review capture output before it becomes saved data. Exercise the actual signed share/widget/notification surfaces separately on a device; source compilation or a simulator run does not establish their distribution behavior.

## Connected review, after the real environment is configured

Run these steps with the submitted build and the isolated review household. The current repository's disabled email-provider or child-consent states are intentional availability states, not working substitutes for the following setup.

1. Sign in as the assigned adult shopper through **Settings → Household requests**. Join the fictional review household with existing local work kept private. Verify that the existing local workspace is not uploaded automatically. Sign out, background/reopen and check protected-account access.
2. Enroll the second verified adult and contributor through the real invite process. The contributor submits a fictional request and sees only their own receipt/outcome. The shopper reviews its whole-basket effect. Have the second adult propose a change, then verify that only the current assigned shopper can commit it. Repeat a lost-response retry and verify one applied operation.
3. Issue a current cook view for one shop with selected fields, expiry and a designated recipient. On iPhone Safari and Android Chrome, inspect only the granted fields. Review an editor proposal without granting approval authority. Revoke the view and confirm content removal. Preserve the separate dated-message fallback.
4. Use guardian controls with fictional test identities and the configured verification provider. Review the child's own-request scope, consent withdrawal and access loss. An unavailable consent provider must fail closed; do not bypass it with an adult checkbox or a fixture.
5. Open **Settings → Household membership**. Inspect Apple's actual localized price/term, renewal disclosure, privacy/terms, **Restore Purchases**, **Manage Subscription** and the Free path. Test purchase, interrupted delivery, pending/cancelled/unverified outcomes, two named seats, restore with the original purchasing account, wrong-household denial, renewal, expiry and refund. A local StoreKit configuration is development evidence only. Record actual sandbox/TestFlight transaction and service reconciliation evidence separately.
6. Review **Household requests → Account deletion**. Check its scope/status, offline retry, provider erasure and retained receipt behavior in the isolated environment. Check household exit separately. Deleting an account does not cancel its Apple subscription, and local deletion does not recall sent/exported copies.
7. Test optional household measurement only after separate explicit consent. Review coded fields, submit one response, refresh after an uncertain result, then withdraw consent. Existing local pickup feedback must remain separate and must not upload automatically.

## Evidence to retain

For each step record build/version, binary/source identity, OS/device/browser, locale, accessibility settings, fixture, tester, date, result and next action. Attach screenshots only after checking them for private data. Check both launch languages, light/dark, largest Dynamic Type, VoiceOver, Switch Control and Reduce Motion on the planned devices. Have a qualified US-Spanish reviewer check help, billing, support, errors, exports and deletion wording; catalog parity is not human language review. Use [the B11 acceptance reconciliation](B11-ACCEPTANCE-RECONCILIATION.md) and requirement/route inventories for the remaining gates rather than turning this script into a blanket acceptance claim.
