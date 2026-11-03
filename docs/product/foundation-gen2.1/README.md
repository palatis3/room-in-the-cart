# Room in the Cart · Foundation Gen 2.1

**Give Codex [CODEX-MASTER.md](CODEX-MASTER.md).** It is a standalone product and build brief for the US iPhone app: whom it serves, what happens on the family's first pickup, Free and Household, all 52 launch requirements and 27 screens, colors and typography, architecture, calculations, privacy, tickets and launch keywords. For implementation, extract the entire package so Codex can also run the fixtures and inspect the visual references. The app itself has not been built.

**First assignment:** Build tickets B00–B01: the native SwiftUI shell and an account-free offline two-pack comparison from Shop. Check unknown weights, Dynamic Type, VoiceOver, local persistence and both launch languages. Use the sample household only in fixtures. Report what was verified and which device tests remain. On Windows, work on portable contracts or web/service code; iPhone builds require macOS/Xcode. There is no live retailer integration in the first release.

| When you need… | Open |
|---|---|
| Screen count, premium interaction, comparison and test plan | [Experience audit](11-experience-audit.md) · [interactive study](experience/Motion%20study.html) |
| Apple subscription configuration and testing | [Apple billing setup](12-apple-billing.md) |
| The corrections made in Foundation 2 | [Gen 2 audit](10-gen2-audit.md) |
| A release obligation, tier or acceptance example | [Feature register](02-features.md) |
| The precise journey and its failure states | [Screen contracts](03-screens.md) |
| Colors, type, motion, accessibility and historical visual studies | [Design system](04-design.md) · [shared tokens](contracts/theme.json) |
| Client, service, privacy and billing boundaries | [Architecture](05-architecture.md) · [authorization and sync](07-service.md) |
| Quantities, checkout math, recovery or data ownership | [Domain rules](06-domain.md) · [executable relational model](contracts/model.sql) |
| The build sequence, release tests and field gates | [Tickets B00–B11](08-build.md) |
| Which keywords to use and when | [Keyword handoff](09-keywords.md) · [editable planner](launch/Room%20in%20the%20Cart%20keyword%20planner.xlsx) · [listing JSON](launch/listing.json) |
| The evidence behind an older decision | [Research history](01-audit.md) · [source manifest](references/sources.json) · [keyword evidence ZIP](launch/Gen%2015%20keyword%20evidence.zip) |

**Authority.** This is the placement and interaction revision of the second-generation build foundation, following fifteen generations of product research. The current chapters and contracts govern the build; the master is assembled from those chapters. References and the raw evidence ZIP preserve historical decisions, mock data, candidate names and earlier screens. They do not override the 52 obligations, the six boundaries or the one deferred integration (E05). Signing, pricing configuration, child-verification policy, Spanish copy and distribution require the real release process.

**Verify.** In the extracted foundation directory, run `python -B verify.py`. The supported Python series starts at 3.13; the verified configuration is Python 3.13.14 with its bundled SQLite 3.50.4. The database requires SQLite 3.38+ with JSON functions. Run without `-O`. The verifier checks coverage, local links, selected historical digests, the refreshed relational model, inherited scenarios, the assembled master, workbook evidence and Gen 2 and 2.1 regressions. Rebuild the master with `python -B compose_master.py` after editing a chapter. Store test artifacts for a real app build separately; these checks only exercise the reference foundation.
