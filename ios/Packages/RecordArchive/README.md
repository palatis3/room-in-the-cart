# RecordArchive v1

This package stages local records without changing a live workspace. The app validates each native payload through a typed, canonical domain allowlist before applying a reviewed batch. A single atomic manifest commits recovered snapshots and canonical receipts together. File locking, refreshed generations, source erasure markers and exact inserted-copy IDs protect concurrent imports and retries. Copies are matched by origin, record ID, revision and projection; changing content under the same identity blocks the batch. A newer or unrelated local record is never overwritten.

Recovery files use AES-256-GCM through CryptoKit with a random 256-bit user-held key. The key is never included in the file. Losing it makes the file unrecoverable. Helper files use a distinct projection and contain only labels, original amounts/units/language, purposes, actions, status and revision/source/as-of metadata. They contain no native private payload. Media, raw databases, credentials, authority, consent and entitlement state are unsupported.

Limits: 8 MiB input/output file, 500 records per archive or recipe batch, 4 MiB per native record, 48 JSON nesting levels, bounded field lengths. An encrypted container's base64 overhead counts toward the file limit. Unknown versions, projections, native fields and envelope fields are rejected. v1.0 is the first public schema; the prerelease v0 fixture is deliberately rejected rather than treated as an undocumented migration.

## Recipe library file profile v1

Supply UTF-8 JSON-LD containing one object with `@type: "Recipe"`, an array of objects, or an object containing an `@graph` array. `@type` may also be an array including `Recipe`, `https://schema.org/Recipe` or `http://schema.org/Recipe`. Optional `formatVersion`, at the root or a recipe node, must equal integer 1.

Supported fields:

- `name`: required nonempty string, preserved verbatim.
- `recipeYield`: optional string, preserved without guessing servings.
- `recipeIngredient`: optional array of original ingredient strings; unknown quantities remain unknown.
- `recipeInstructions`: optional string, string array, or array of `HowToStep` objects with `text` strings.
- `url`: optional HTTP(S) source URL without credentials. Attribution only; never fetched.
- `notes`: optional string; otherwise `description` supplies notes.

Other fields are reported, unsupported rows are skipped and duplicate content is identified. No context fetching, website traversal, script execution or remote parsing occurs. The preview shows staged recipes, duplicates, skipped rows and unsupported fields before one atomic batch is saved. Undo removes only copies actually inserted by that batch. The native recipe adapter preserves the original recipe and requires a person to review servings and quantities before adopting a dinner.

Run focused tests with `swift test --package-path ios/Packages/RecordArchive --scratch-path /tmp/record-archive-tests`. App composition and simulator validation are separate integration checks.
