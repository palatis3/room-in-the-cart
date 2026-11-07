# Inputs and dependency provenance

The user supplied `/Users/palatis/Downloads/Handoff/APP-BASELINE.md`, `MASTER-GENERATION.md`, and `foundation-gen2.1/`. The baseline was read first; the Foundation requirements and acceptance gates govern implementation, while the master explains product/research history. Document text was treated as product context, not as authorization to distribute, spend on campaigns or communicate with unrelated people.

The actual working folder was empty at inspection. No legacy Expo source was present to overwrite. The implementation starts at B00–B01.

`shared/contracts/theme.json` is copied from the accepted Foundation 2.1 token contract. App color assets and web CSS are generated from it. Pack fixtures are newly authored fictional arithmetic examples; there is no real household data or embedded research participant data.

Swift packages have no third-party dependencies. SQLite comes from the operating system. SF Symbols/system typography are used through platform APIs. TypeScript 5.7.3 (Apache-2.0) is a pinned development dependency in the web/service lockfiles. The initial scaffolds had no runtime dependencies; the current service includes the dependencies recorded in its package manifest and lockfile for database, authentication and Apple integration.

Initial local build tooling used the official Node 22.14.0 macOS arm64 archive. The current pin is Node 22.23.4, a published security release. Its official macOS arm64 archive was checked against nodejs.org's SHASUMS256.txt and is kept under ignored `.tools/`. The earlier binary remains for reproducing historical evidence; historical test records retain their actual version. CI checks the current pin against the official release index and support schedule, including its major version's latest security release. [Upgrade validation](evidence/native/node-runtime-security-20261105/validation.json) · [Node release](https://nodejs.org/en/blog/release/v22.23.4)

User-local uv 0.13.7 provisioned CPython 3.13.18 to run the supplied reference verification. System Python was not replaced.

No Figma asset, stock photography, generated image, retailer credentials, signing secrets or production service credentials are required by this milestone. Spanish UI copy is structurally validated but still needs a human language review.

The three original dinner patterns in `ios/Features/Dinners/DinnerPatternCatalog.swift` were written for this app. Their quantities and time estimates are editable starting points. No external recipe or retailer feed is involved.
