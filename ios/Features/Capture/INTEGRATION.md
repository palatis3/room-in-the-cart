# Capture integration — B09 remains open

`CaptureReviewView(initialText:initialSource:localeIdentifier:destination:existingCapture:correctionScope:authorize:onReviewed:)` provides typed entry, explicit paste, optional on-device speech and selected-photo OCR. `authorize` is required. Captured words are accepted explicitly, then every item’s name, total/unit, pack count, usable amount per pack, purpose, destination, exclusions and unknown fields are reviewed. Material edits clear confirmation. Ambiguous and negative wording remains visible beside the original. No field, spoken destination or captured role label grants authority.

## Private Ledger entry and atomic import

`LedgerImportView` presents this sheet from **Capture and review fields**. It binds the sheet to the current unlocked local workspace, installation actor, shop ID/revision, account/member/role and locale. Helpers, contributors, unknown shared contexts, locked access and pending workspace erasure cannot start capture. Any change invalidates the staged result. This is the private Ledger path; it does not submit household requests.

`ReviewedCapture` carries a stable operation ID, original source wording, editable text, typed `[CaptureImportLine]`, stable per-line/proposed-line IDs, editable field drafts and optional in-memory photo evidence. `CaptureLedgerImport.stage(_:in:)` calls `ShoppingLedger.stageCaptureImport(id:originalText:source:lines:)`. All fields then commit in the existing single `commitImport` operation after explicit duplicate decisions. There is no text import followed by metadata mutation. Exact repeated callbacks return the existing receipt; changed or undone replay is rejected. Editing captured fields restages the same operation and line IDs before Apply. A supplied total conflicting with complete pack arithmetic is rejected; incomplete quantities stay visibly unknown. Purpose and destination remain labels, not meal/protected-group or shared-request routing.

`CaptureSource.photoOCR` maps to `ImportSource.photoOCR`. Other mappings are typed → typed, paste → paste, speech → voice. The original selected photo and a bounded preview survive capture and duplicate review in memory, then leave with the view. They are not persisted as attachments or uploaded. Original wording and typed metadata persist through the domain import receipt and contribution evidence.

## Optional spelling corrections and erasure

`CaptureCorrectionScope(profileID:localeIdentifier:)` is a nonthrowing initializer. The actor validates opaque profile IDs and English/Spanish locale scopes. Private Ledger supplies `"local:" + sourceWorkspaceID.uuidString`; this is its device-owner-gated local workspace, not a shared-account fallback. A shared request host must supply its verified profile scope explicitly. Missing scope hides correction memory controls while typing still works.

The adult contributor review uses the enrolled account subject, household and member from its current own-request lease. Its files live in a separate, hashed account directory and use the same capture language as recognition. Leaving, locking, or switching households hides the prior scope until that same profile is verified again. Confirmed account deletion retires the account directory across memberships and languages. The receipt can retry blocked local cleanup. The contributor sends only the separately reviewed request.

`CaptureCorrectionStore.shared` is local only. Users explicitly opt in, remember, use a suggestion, forget, or opt out. Opt-out deletes the current profile/locale entries. Exact product-spelling suggestions never apply automatically or rewrite old records. Numeric, negated or allergy/free-from fragments cannot be saved as spelling rules. Limits: 100 entries, 160 characters per fragment, 128 KB file. Files use complete protection and are excluded from backup; no audio or complete transcript is stored. Scope changes discard in-memory suggestions and late responses.

`CorrectionSettingsLink()` exposes that same model/store directly from Settings. `CorrectionSettingsView` requires the current device-owner-gated private identity, active scene and live ledger workspace, with no pending ledger deletion. It lists or forgets remembered spellings for an explicitly selected English/Spanish scope; it does not add new rules outside reviewed capture. Turning memory off confirms deletion of that workspace/language only. Cached text is hidden as soon as the live scope differs, and cancelled loads cannot clear a newer scope. Failed reads or writes require reload before controls or a saved-spellings list return. This is local spelling management, not shared-account correction memory or an export.

Forget buttons have a target-specific accessible name containing the original and replacement. Actions produce a visible scoped result row from the model's reloaded snapshot; unconfirmed writes never receive success copy. The result remains after the removed button disappears. `ScrollViewReader` and `AccessibilityFocusState` scroll/focus that stable row after layout yields, with cancellation and live-context checks. Scope/access changes and leaving the screen clear private result text. `CorrectionSettingsOutcomeTests` verifies distinct target labels, post-operation absence for forget, empty/disabled state for opt-out and uncertainty handling. Device/VoiceOver focus execution remains part of the integrated UI review.

`RecordsRecoveryLink(accessibilityID:)` is shared by Records and Settings. It composes the same `RecordsToolsEntryView` with device-surface and capture-profile erasure callbacks, so the Settings entry cannot bypass retirement cleanup.

Root’s required Records cleanup must call:

```swift
let scope = CaptureCorrectionScope(profileID: "local:" + retiredWorkspaceID.uuidString,
                                   localeIdentifier: "en-US")
try await CaptureCorrectionStore.shared.eraseProfile(scope)
```

The locale argument does not limit erasure: all locale files for that profile are removed. A content-free hashed retirement marker prevents late recreation across restart. A storage failure throws so the Records erasure journal remains retryable. Normal default directory: `Application Support/RoomInTheCart/CaptureCorrections`; DEBUG `--ui-testing`: `Application Support/UITestWorkspace/CaptureCorrections`. An injected directory is preserved. There is no automatic reset of development profiles.

## Guest proposal port

`GuestCaptureReviewView(meals:localeIdentifier:authorize:onPreview:)` is a separate reusable review sheet. It requires explicit meal and nonprotected group selection, a reviewed new total and confirmation. `ReviewedGuestCapture` contains `id`, `originalText`, `occurrenceID`, `groupID`, `baselineServings` and `total: Rational`. The host must re-fetch the current meal/group, verify the baseline and protected status, replace only the selected group’s total, and call `DinnerFeatureModel.previewGuests(occurrenceID:servings:isolated:)`. Only the existing planner’s later Apply may commit. This sheet does not call Apply. The Dinners entry wiring is a separate pending integration; grocery capture never changes guest counts implicitly.

## Permissions and device behavior

Root owns `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` plus their English/Spanish descriptions. Missing descriptions, denied permissions, unsupported languages and unavailable microphones retain typed entry. Speech requests permissions only after a tap, accepts en-US/es-US, verifies on-device support and requires on-device recognition. It never falls back to a speech server. Recording stops on user action, final result, close/background or after 45 seconds. Raw audio is neither saved nor logged.

PhotosPicker requests only the selected image, without broad photo-library or camera permission. System retrieval of an iCloud-backed selected photo may occur before delivery. Vision OCR is local, disables language correction, and preserves uncertain wording. Bounds: 20,000 characters/200 lines, 12 MB/30 megapixels per image, downsampled to 2,500 pixels. OCR cancellation and generation checks discard stale work. Paste reads only after the user’s action. None of these paths verifies prices, payment, safe ingredients or arrival.

Cook readback is documented in `READBACK.md`; it uses an explicitly authorized current projection and local synthesis, with VoiceOver exclusive. It is separate from capture and guest proposals.

## Evidence and remaining work

The isolated combined suite has 43 passing tests, including actual local Vision OCR, deterministic three-row reading order, bilingual structured parsing, negation/unknown/pack conflicts, material edit confirmation, exact/changed/undone replay, correction opt-in/forget/locale/profile isolation, erasure late-write rejection and DEBUG directory isolation. All 115 en/es catalog entries compile. SDK checks are development evidence, not physical-device acceptance.

Still required: root native/runtime integration checks; physical microphone and permission refusal tests; airplane-mode recognition availability; noisy speech and low-light bilingual photo review; large text/VoiceOver and human US-Spanish review; shared contributor request-only capture routing; actual Dinners guest entry; physical camera/barcode/manual product matching; native runtime verification of persistent package attachments and receipt/recipe-specific review. Optional widgets/share/reminders and print/aisle work have separate owners and device gates. B09 is not complete.


## Integrated scan and reviewed recipe routes (2026-11-03)

`LedgerIngredientView` → **Package photos and barcode references**; `PickupSettlementView` → **Receipt photos and reviewed lines**; Dinners → **Review a recipe from text or photo**. All bind to the current unlocked private actor, adult account/member context, native storage namespace and source revision. A recovered document cannot authorize native media lookup. Capture and source display stop when authorization changes.

Camera/photo processing requires a per-review explicit local-only consent toggle. Typing and explicit paste remain available without it. Revoking consent cancels pending photo/recognition work, removes in-memory photo evidence and rejects late results while retaining editable text. The app never uploads photos or invokes a barcode product catalog; an iCloud-selected photo may be retrieved by the OS. Camera use is still-photo only and requests neither microphone nor photo-library-write access. English/Spanish camera-purpose strings are in Info.plist and InfoPlist.xcstrings.

`CaptureMediaStore` writes reduced JPEGs and literal reviewed evidence with complete protection and backup exclusion. Maximum 12 records per namespace, 1.5 MB per image and 2.1 MB per encoded record; no automatic eviction. Package references and receipt rows can be reviewed and removed individually. Receipt quantities/amounts are literal notes, not financial entries or physical receipt events. A barcode requires explicit manual matching and conveys no safety, price, or purchase claim.

Recipe OCR is a bounded bilingual suggestion parser, followed by editable title/servings/source/notes and structured ingredient review. **Accept reviewed recipe** saves a reusable candidate; choosing for the shop remains a separate dinner-library action. Original text and optional opaque media reference persist in `RecipeSourceEvidence`; editing a dinner version preserves them, and both choose paths copy the evidence into the occurrence. Source URLs are attribution only and are never fetched. Typed recipes need no media sidecar. Source photos can be reopened or deleted through the authorized native recipe's **Original recipe source** route; unavailable media never invalidates the editable recipe. Readable and helper exports preserve permitted source wording without attachment bytes. Records can explicitly include selected source references in an encrypted owner recovery file after a size/content disclosure. A bounded typed/digest manifest and typed reduced-JPEG validation protect the staged batch; recovered references are browsable with the separate recovered copy and never authorize a lookup in the original media namespace. Local removal markers scrub matching embedded evidence from earlier recovered copies.

Foreground tombstone reconciliation and Records deletion both call the media cleanup from `DeviceSurfacesComposition.eraseLedgerWorkspace` / `erasePickupRecord`. Retirement markers survive restart and reject late saves. Cleanup failures propagate so the durable deletion journal retries. A failed/uncertain recipe save retains its source sidecar for exact retry or workspace erasure, never deletes potentially committed evidence.

Host/SDK integration evidence is recorded separately. No physical-device, simulator UI, VoiceOver, permission-denial, low-light capture, or human Spanish acceptance is implied by host tests.


Barcode compatibility: use the current Vision detector first. If it errors or finds no valid codes, make at most one supported revision-2 pass using each stage's supported CPU device. This addresses the iOS 27 simulator inference-context failure reproduced with generated QR images. Cancellation is checked between passes; both results remain untrusted identifiers requiring manual matching. The test retains its exact payload assertion. This simulator evidence does not certify physical camera conditions.
