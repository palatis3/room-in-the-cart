# Independent correlation review

**Initial findings, subsequently resolved in the revision below.** Source inspection found two concrete incomplete/contradictory-evidence paths and one loader ambiguity. None changes the original native metric verdict; the risk is overstating diagnostic evidence quality. Counterexamples below were reasoned directly from source, not executed. No test, native tool, build, network or Git command was run.

## Findings

1. **Started instances without a report disappear from lifecycle validation** (`correlate.py:26–33,62–66,106–110`). The code checks lifecycle only for instances in `reports`. Starting from the existing valid fixture, append a new distinct instance with `created`, `willBegin`, `didStop` but no `report`; update sequence, totalEvents and totalInstances, leaving six reports and six uniquely mapped activities intact. All present inventory checks pass; no issue is added for the incomplete instance and status becomes observations-only. A created-only original metric instance can be legitimate and must not automatically count as an iteration, but any instance with measurement lifecycle callbacks and no report needs an explicit incomplete/needs-review classification. Validate every instance's lifecycle, with a deliberate policy for unused created-only objects. Add a regression that retains all six valid reports plus the incomplete extra instance so unmatched activities cannot accidentally hide the hole.

2. **Claimed one-process evidence is not checked against endpoint tokens** (`correlate.py:35–50,93–98`). Change both endpoints of one valid swipe window to `process-2`, retaining the other windows' process-1 and the top-level matchedProcessCount=1. The per-window equality check still passes, all windows map, and observations-only is emitted. The retained receipt now contradicts its single-process claim. Recompute distinct process tokens across endpoints selected by the six swipe windows and reconcile with matchedProcessCount; do not use wider reset/inter-window events for that count, because the source parser intentionally computes matchedProcessCount only over swipe windows. Require string tokens of the expected form rather than mere truthiness. Add this internally consistent-pair/multiple-window-process negative case.

3. **Duplicate JSON keys silently overwrite evidence fields** (`correlate.py:125`). Plain json.loads accepts duplicate keys at every nesting level. A duplicate `omittedEvents`, status or supplied timestamp key can erase a contradictory value before validation and still produce observations-only. Input hashing preserves the original bytes but does not make that parse unambiguous. Use a duplicate-key-rejecting loader and add a CLI/input-decoder regression; the current tests call analyze on dictionaries and cannot exercise this issue. This is a bounded evidence-loader correction, not a request to change the endpoint generation schema.

## Validation breadth and useful behavior

The current 'valid' fixture omits fields the real witness always emits (callbackUptime/callbackUnixUTC) and several schema-2 receipt fields (receipt diagnosticOnly, maximumRetainedEvents, endpoint windowIndices). The correlator consequently demonstrates a partial projection validator, not strict rejection of all malformed/partial producer receipts. Define the required input schema explicitly and test with producer-shaped fixtures. In particular, validate typed counters/schema values without accepting booleans as integers and avoid silently coercing totalInstances from arbitrary values. Fields deliberately unused for correlation can be documented as such, but the report must not claim complete schema validation if they are ignored. Recomputing selected windows by timestamp is useful; do not begin trusting unverified windowIndices instead.

The substantive correlation logic otherwise remains conservative: finite supplied UTC and UInt64 clock representations are checked; nonpositive intervals are unavailable; UTC/monotonic discrepancy adds a review issue without pretending 1 ms is an accuracy guarantee; unique overlap is required; duplicate mapping/lifecycle/pair problems are retained; signed containment margins are not clamped; unmatched activity indices stay visible instead of being labelled warm-up and removed. `numericallyContained` is only arithmetic containment, and edgeWithinOneMillisecond is only an explicit proximity flag. Neither establishes clock accuracy, collector delivery or acceptance.

The output correctly starts unavailable and remains so on caught malformed input. It can retain earlier partial observations when later validation fails; consumers must honor the top-level unavailable/needs-review status rather than cherry-picking rows. Snapshot/lock ordering limits from the separate witness review still apply. Input path/hash records identify these two files but do not independently bind their selector, owned device, native result, source/product or invocation; retain the external package provenance requirement before interpreting real-run output.

## Inspected validation and provenance

`correlation-checks.log` records 13 passing offline cases. This review did not rerun them. The cases cover ordinary mapping, absent/truncated evidence, nonfinite/reversed report bounds, clock disagreement, duplicates, unmatched warm-up candidate, outside-pair margins, bad process count/unparsed count, token mismatch inside a pair, missing lifecycle in a reporting instance and ambiguous overlap. They do not cover the three specific findings above.

The copied endpoint parser and its tests were byte-compared with the previously reviewed proposal; both match their provenance hashes. Its retained checks.log records 16 passing cases. No change to that existing parser is requested by this review. Only this correlation-review.md was written.

Reviewed file SHA-256:
- `correlate.py`: `fd2c559b5d42eaa46c251ce8a4fe3c2a63f902fe2547188f2483a71b65fb235f`
- `test_correlate.py`: `5b3dbc5a2928ae51cb1e1bb86fdcf9f0b385a591db2dd18dace5fd7e2240bdd4`
- `correlation-checks.log`: `46c74e95e49409273cff5b0d474bb3f780e57977a4af5da2071b99cd4731838f`
- `endpoint-parser/scroll_signpost_diagnostic.py`: `be4a3f473c7e5dc6bc952df4c82e350a8ad58c4c2fb8721e71efabfa441f7de9`
- `endpoint-parser/test_scroll_signpost_diagnostic.py`: `a3b94cec9424acfed37a1e102c5f79ef240d984154ecc80ee31e6dbd78942c4c`
- `endpoint-parser/provenance.json`: `6b145d9126fc2d43a92b19f44d8e1d40080ae02df0a3dff8f979f495407dbe40`
- `endpoint-parser/checks.log`: `cb911b310ccb3daadcab815b43af6edf4c098f9348c2c9dd39e6de244666d0ae`

## Revised implementation resolution

Re-read root's revised correlate.py/test_correlate.py and retained correlation-checks-v3.log. **All three concrete findings above are resolved; no remaining blocker found for the bounded correlation calculation.**

- All created instances are inspected. An instance with only `created` is retained explicitly in instancesWithoutReports; any started/stopped instance without a report adds a needs-review issue. The new negative case keeps all six valid mapped reports, so it directly catches the original hole.
- Endpoint windowIndices are checked against independently recomputed timestamp memberships, then process tokens are unioned only across actual gesture-window events. Contradictory cross-window process identity is unavailable; wider reset/inter-window events do not distort that invariant.
- The CLI now uses unique_object as object_pairs_hook; duplicate keys at any object depth raise ValueError before analysis. The new loader test demonstrates the shared hook's rejection. Callback observation clocks must also be present/finite and endpointEvidence must be diagnosticOnly=true.

The retained v3 log records **19 passing offline cases**. This review did not execute them. The added tests directly exercise the three findings plus unused created-only instance visibility, missing callback clocks and incorrect endpoint window inventories. The root witness implementation, measurement body and baseline are outside this correlator revision.

Remaining scope limit: it validates the projection required for correlation, not every field/type of the complete producer schemas. Some counters use Python numeric equality, totalInstances uses int conversion, token grammar is not strictly checked, and unused producer metadata is not validated. Therefore do not describe this as rejecting every malformed schema. These limits do not reopen the resolved missing-report or contradictory-process classifications. Native result/source/device binding remains the external provenance requirement. Preserve all earlier clock/receipt/nonacceptance limitations.

The first hash list was captured while root was updating these scratch files, so it should not be treated as a frozen identifier for the initial source inspection. The revised files inspected for this resolution are pinned below:
- `correlate.py`: `fd2c559b5d42eaa46c251ce8a4fe3c2a63f902fe2547188f2483a71b65fb235f`
- `test_correlate.py`: `5b3dbc5a2928ae51cb1e1bb86fdcf9f0b385a591db2dd18dace5fd7e2240bdd4`
- `correlation-checks-v3.log`: `d604d5b4a307d14f9b407f9dc4ec3c155113ee4ba72b98ed71fc618e7f6974db`
