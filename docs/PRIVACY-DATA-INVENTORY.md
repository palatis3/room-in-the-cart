# Privacy data inventory

Implementation inventory, 2026-11-03. This supports the native privacy manifest; it is not a published privacy policy or completed App Store privacy questionnaire. Reconcile it with the final submitted build and live provider settings before distribution.

The ordinary local Free workflow keeps its workspace on the iPhone. Signing into a household does not upload that existing workspace. Optional authenticated features transmit the specific account, household, request, shared-shop or billing data needed for those features. The manifest describes those optional collection paths even while email setup and real App Store product configuration remain deferred.

| Apple category | Implemented collection path | Purpose |
|---|---|---|
| Name | Household member aliases, entered by people; `service/migrations/001_household_requests.sql` | Attribute household actions and requests |
| Email address | Supabase email authentication; `ios/Packages/HouseholdClient/Sources/HouseholdClient/AdultAuth.swift`, `service/src/browser-auth.ts` | Sign-in and account authentication |
| User ID | Verified provider subject, household member IDs and billing purchaser binding | Authorization, account records and membership |
| Device ID | Enrolled device/session identifiers in the household service | Authenticate and revoke an enrolled device; not advertising |
| Other user content | Explicitly submitted household requests, shared shop content, instructions and proposed changes | Household collaboration |
| Other financial information | Reviewed shared-shop spending caps, quotes, shopper-entered charges, credits, holds, price observations and budget periods | Evaluate the shop budget, display the assigned shopper’s evidence and calculate authorized period totals |
| Purchase history | Verified Apple membership transaction/original-transaction identifiers and subscription state | Deliver, restore and revoke membership correctly |

All listed data is treated as linked to identity, used for app functionality, and not used for tracking. These declarations do not authorize new uploads. Existing authorization and explicit review boundaries still control each transmission.

Raw voice recordings are not retained or uploaded by the app's on-device capture path. Photo/OCR review and local correction data stay local unless the person explicitly submits reviewed text through a sharing feature. Local benchmarks and the app's redacted diagnostic sink are not a remote analytics service. Apple handles payment credentials; the app receives membership transaction evidence, not a payment card or bank account number.

Required-reason API declarations currently cover app-owned UserDefaults access (`CA92.1`). The release review must recheck required-reason API usage and manifests in all shipped targets after any SDK or framework change. The share/widget targets are narrow local surfaces, not additional account-data upload clients.

The final owner still needs to supply public support/privacy/terms destinations, review provider retention and deletion settings, and complete App Store privacy disclosures against the submitted build. Child network enrollment remains disabled until the actual consent/verification process is configured and reviewed. No child-verification provider is represented as operational here.

Apple references: [data collection manifest instructions](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest), [supported data categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype), and [privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files).


Optional scan evidence: the camera/photo route requires per-review on-device-processing consent. It stores reduced JPEG references (location metadata stripped), original text, explicit product matches and literal receipt annotations only in protected, backup-excluded app-private storage. The bounds are twelve sidecars per namespace and 2.1 MB per encoded record. Individual reference removal, recipe-photo removal, pickup deletion, and whole-ledger deletion retire the corresponding evidence; foreground tombstone replay retries cleanup and prevents late recreation. Typed recipes retain original text in the recipe without a media sidecar. No photo bytes are exported or uploaded. Apple may retrieve an explicitly selected iCloud photo before delivering it to the app. This adds local storage, not a new remote collection path.

Shared placement evidence: explicit capture preserves the original authenticated shop snapshot, review time, authority epoch, actor/device binding and immutable report/reconciliation retry bytes in protected, backup-excluded local storage. Sending transmits the reviewed command's snapshot reference and occurrence time, not the private local ledger. Reporter status is minimal and remains distinct from current-shopper reconciliation data. Sign-out/account deletion and scoped household exit purge local evidence with a deletion epoch; a separately device-authenticated offline view can reopen only the retained native actor's original evidence, never current shopper authority. These reports are manually entered external-order evidence, not retailer or payment verification.

Optional pickup feedback starts off. Enabling it offers a prompt only on a closed, reported pickup. A saved response contains three codes for outcome, usual workflow and comparison with that workflow. It belongs to the pickup in the private local workspace and can travel in an explicitly exported owner recovery file. The app does not transmit it to an analytics service. Removing the response clears the current local record. Exported copies remain under their owner's control.

Local handoffs store a recipient label only when the shopper marks a specific saved cook note or retailer snapshot as sent. Each send and separately reported acknowledgment belongs to that pickup. Removing the pickup erases its local recipient history. An owner recovery file can include these records. Recipient labels, private budgets and historical custom wording are excluded from generated change lists. A full copy with custom or private wording requires a separate review. Copy, share-sheet completion and recipient acknowledgment are distinct actions.

Family decisions start as private pickup evidence. An authorized shopper chooses the shop and reviews a copy before sending it to the household service. The copy can contain dish, product, occasion, preference and explicitly observed outcome. Paid search and retention of a preference require a current named seat. Local pending commands are protected, excluded from device backup and cleared on authority loss. Account erasure removes authored records, strips the erased person's contributions and invalidates affected retry receipts. [Household decision contract](../service/API-DECISIONS.md)

Pantry and freezer batches store the household's food label, usable quantity, observation time, reviewed food identity and optional use-first choice in the local pickup. Reservations are derived from the confirmed quantities and meal priorities. Batch details can travel in an explicitly exported owner recovery file.
