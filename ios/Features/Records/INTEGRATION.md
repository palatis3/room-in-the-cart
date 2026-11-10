# Records storage and selected-media recovery · F07

**Scoped acceptance, 2026-11-03:** the recovered-store capture extension compiles and passes 49 affected native checks plus the actual media screen flow on iPhone SE / iOS 17. RecordArchive passes 33 tests, including v1.0/v1.1/v1.2 fixtures. The final selected/recovered photo rows, sibling review and automatic result anchors were visually inspected. [Exact evidence, source/binary manifests and six final screenshots](../../../docs/evidence/native/f07-recovered-20261103/evidence.json) describe clean baseline `ec1c243` plus reviewed F07 overlays; in-progress guardian and civil-date changes are excluded. A fresh whole-checkout integration build is still required.

Records → **Recovery, exports and saved records** opens the production `RecordsToolsEntryView` and `RecordsToolsView`. Selecting a record does not select its source references. Encrypted recovery shows each available package/receipt/recipe reference, a reduced-photo and original-wording preview, selected count/size, private-content disclosure and a separate user-held-key acknowledgment. Readable and helper copies contain no attachment bytes. Full-size originals, missing photos, raw voice, credentials, membership, consent and live permissions cannot be recovered.

No-media archives retain the existing v1.0 encoding and base projection. v1.1 adds an owner-bound, versioned typed media manifest with exact sizes/digests. Bounds are twelve references, 2.1 MB per encoded evidence attachment, 4.2 MB combined evidence, and an 8 MiB final file including encryption overhead. The app re-decodes/re-encodes the evidence allowlist, verifies reduced JPEG type/dimensions and checks local erasure markers before staged review and apply. Selected media IDs extend each record's receipt projection: identical selected content reopens once, another explicit subset is a sibling, and changed content under the same identity is quarantined.

Records and selected evidence commit in the same atomic registry file. Cancel, corrupt media and unsupported files leave the batch unapplied; newer/current work is retained. Recovered photos are read from the selected committed copy, without looking up its decoded namespace in the live media store. Re-exported edited shops/libraries retain only attachments still owned by the emitted typed record. The original registry source can retain its historical evidence.

Active private identity, workspace identity and lifecycle generation are captured and rechecked across asynchronous boundaries. Internal recovered media uses complete file protection and is excluded from system backup. Decryption uses memory without plaintext staging files. Known reference-removal markers atomically scrub embedded evidence from earlier recovered copies and deletion undo while preserving their copy IDs, remaining record bytes and isolated edited workspaces. Optional corrupt local sidecars remain untouched, appear as unavailable references and do not prevent healthy native-record backup.

New source references captured inside an independently recovered ledger or pickup retain the actual physical store UUID. Only an opened fixed `ledger.sqlite`/`pickup.sqlite` inside the app-owned recovery-copy directory mints a runtime scope. Fresh projection lists that physical namespace and checks the emitted native shop/line/recipe/receipt binding before attaching evidence. v1.2 maps this unchanged physical capture ID to the original logical archive origin; imported declarations are inert and never drive native listing, paths or cleanup. v1.0/v1.1 bytes and selected-ID receipt identity remain compatible.

The protected `capture-scope-v1.json` journal binds the recovery-copy ID, kind and physical SQLite identity, with bounded canonical bytes and digest validation. Cleanup checks it against the actual fixed database; missing legacy journals derive their identity from that database. Unknown/future fields, foreign IDs and symlinks fail closed. Cleanup protects active root IDs, retires recovered sidecars and every correction locale, then removes the directory. Registry deletion/undo cancels shared in-flight recovery leases before mutation, dismisses its destination and drains store users before filesystem removal. Opens recheck the current registry receipt after awaited work. A source-media scrub retains its copy ID and edited directory; stale cancelled opens cannot replace a completed deletion result.

## Executed evidence

- RecordArchive package: **33/33** tests passed, including legacy, v1.1 and v1.2 fixtures, encryption, selected-subset deduplication/siblings, mapping validation, manifest corruption/type/size bounds, transactional cancellation/undo and durable source-media scrubbing.
- Historical pre-extension integrated native suite: **438/438** passed in [ResumedReviewedNative.xcresult](../../../.build/ResumedReviewedNative.xcresult), including `RecordsMediaTests`, `RecordsAdapterTests`, `RecordsListingTests` and capture-media tests. The recovered-edit regression covers removed reference targets, another shop and a new meal-library projection, successful encrypted backup and preservation of the historical source.
- Current scoped native checks: **49/49**, plus **28/28** structured-capture, media-store and correction checks, pass against the final frozen product set. This includes restart/locale retirement and late-callback protection.
- English/Spanish catalog coverage and whitespace checks pass. Human US-Spanish and physical-device accessibility review remain release checks.

## Dedicated native screen acceptance

`RecordsMediaUITests` uses the actual Records entry and screens with isolated native stores and a real normalized JPEG. `RecordsMediaUIFixture` is compiled only under `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE` and requires both `--ui-testing` and `--records-media-fixture`. It seeds a private local source and a newer independent related copy. Its guarded file adapter replaces only the system save destination and selected-file URL; production encryption, scope validation, staged review, cancellation and import remain in place. It checks default-off selection, size/private-content disclosure, preparation gates, ciphertext output, cancelled sibling review with unchanged source/registry, confirmed recovery and readable recovered-photo presentation. The final combined model/screen bundle passed **50/50** in `.build/F07-Recovered-UIFinal.xcresult`; the screen journey took 205.989 seconds. All seven manually attached screenshots were visually inspected. The prepared-file image/AX remains only in ignored local build evidence because it contains an ephemeral fixture recovery key. Passive review rows are scrolled into view before inspection; automatic completed-action status checks do not scroll.


## Shared historical entry points (November 10)

Records now includes **Shared pickup records**: find a past shared pickup, open
its existing household-shop screen, or open placement reports directly. The
history picker defaults to **Shops assigned to me**, whose existing service query
includes closed pickups. Other callers retain the active-shop default. Selection
uses the existing household selection/authorization path. The selected shop's
existing routes expose confirmed orders, deliveries, saved cook copies and
financial evidence subject to their current permissions; no new data store or
permission was introduced. Original saved placement evidence retains its existing
unlock path when household access has ended.

The separate Records entries for family decisions and price/period history remain
in place. Browsing these records does not establish that all their historical
content is included in the current shared snapshot backup; that export gap remains
explicit follow-up work.

Validation: app build passed (`.build/SharedRecordsNov10/history-navigation/build.log`),
changed Swift syntax passed, and localization checks passed30catalogs/4,745entries.
No new end-to-end walkthrough or broad regression was run for this navigation edit.


## Selected shared historical backup (November 10)

Data and recovery now lists a separate **Shared pickup history** for the selected
assigned-shopper scope. It reads `/records/history/v1` afresh and includes saved
basket/meal revisions, dated cook text and marked sends, deliveries and food
reservations, family decisions, financial evidence and saved price observations.
Optional `foodHistory` and `stockHistory` now retain exact demand graph ancestry,
pack reviews, tracked/unbound quantities, selected-shop stock lots and observation,
selection, match and reservation chronology. A released reservation is labeled as
released; unknown stock remains distinct from confirmed zero. Older archives keep
their original bytes and explicitly disclose sections that were not captured.
Normal removed-meal revisions retain an explicit null marker. A historical file
is an independent encrypted/readable record; it never supplies household access,
consent, commands, replay receipts or live financial authority. Helper export of
this private history is denied. Reimport reopens the same content once; known local
erasure markers still prevent recovery.

The existing server transaction rechecks current shopper scope and contributing
members/consent before reading payloads. `stockHistory.carriedDeliveries` adds
selected physical source ancestry from other pickups and its complete arrival/
usable correction chain, with no foreign budget, basket or meal list. Older stock
archives without the field retain their bytes and explicit missing-capture status.
Physical-stock scope survives source-shop authority transfer. Opaque edited cook
text instead requires current assigned-shopper scope on every recorded source
shop. Retired/erased/missing sources or bounds make the affected history export
unavailable; current snapshots remain a separate option.

Focused server checks pass12/12 and Swift decoder/client checks pass11/11. The
actual PostgreSQL suite passes444 with3separate browser skips, including carryover,
known/unknown/zero corrections, source authority loss and retirement. Logs:
`.build/SharedRecordsNov10/carried-history-database`; disposable cluster stopped
and removed. App build and11archive/erasure checks pass with0skips/0runtime warnings
in `.build/SharedRecordsNov10/carried-history-native`. Those include four existing
local cleanup/restore checks, not a new recovery subsystem. Known local erasure
markers continue to prevent import; household reattachment never derives access
from files. Actual authenticated lifecycle and human/device walkthroughs remain.
