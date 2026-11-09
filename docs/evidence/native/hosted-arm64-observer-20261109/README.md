# Hosted ARM64 producer and runtime observation

[Run 42639339096, attempt 1](https://github.com/palatis3/room-in-the-cart/actions/runs/42639339096)
tested exact commit `dc343f3e714f9e66cd8de09ad8942093072b66be` and is terminal.
The optimized producer and original scroll XCTest passed; the overall run failed
because required scroll duration remains absent. No baseline or release approval.

## Verified improvements

- Producer and both consumer receipts bind the same plan, five executable products
  and protected inputs. The arm64-only plan is unchanged across archive/restore.
- The coordinator downloaded the original 45,367,504-byte product ZIP once and
  verified its GitHub SHA256. Direct Mach-O reads confirm the app, UI tests, share
  and widget extensions, plus all five static package objects, are arm64-only.
  The initial inspection expected embedded dynamic frameworks; the archive instead
  contains five static `.o` products, which were then inspected. No product changed.
- Build logs contain 301 SwiftCompile records, nine compiler-wrapper commands and
  nine link outputs for arm64, with none for Intel. The prior dual-architecture
  run logged the same counts for each architecture. These are recorded command
  lines, not an instrumented compiler-process trace.
- Build step: 451 seconds versus 618 in the earlier run. Different source/cache/run
  conditions prevent a controlled speedup claim. Fresh setup took 188 seconds;
  simulator preservation and cleanup succeeded.

## Diagnostic finding and limits

The native scroll case passed 1/1 in 136.301 seconds, and SQLite remained
500 rows / 500 contributions / 0 checkoffs / revision 3. Three memory series each contain
five samples. Strict validation correctly fails on missing
`com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration`.

The producer's declared checker path is absent in the consumer both before and
after setup. Nevertheless, its selected runtime contains the same 338,880 checker
bytes, SHA256 1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8,
and the runner actually observes matching arm64 UUID
`E40A186A-8D7D-3029-B5CD-D42C967992C0` after measurement. RPAC has no match.
The complete post-measure report matches the local report exactly except PID:
1,130 callbacks, 5,263,912 parsed bytes, no budget overrun. Attachment, owned device,
producer receipt, selected runtime and exact test selector are bound together.

This closes the post-measure runner-image identity question. It does not prove
activity during timing windows, AUT-process loading or metric causation. The
post-hoc signpost query also reports zero matching events; absence there does not
establish whether events were emitted or transported. Do not repeat unchanged
checker-path/image probes, rewrite the test plan or disable checkers on this evidence.
The next experiment needs to distinguish measurement collection/transport or the
relevant application environment before another expensive native run. Minimum-iOS
qualification and final combined regression remain open.

## Retained originals

All three original ZIPs match GitHub's published digests. The monitor inspected
only the small evidence ZIPs; the coordinator additionally inspected the product
ZIP without extracting or executing it. Original receipts and local failures remain
unchanged. No independent remote archival claim is made.

| Evidence | SHA256 |
| --- | --- |
| Terminal report (`.build/HostedLoadedImagesNov09/monitor/terminal-loaded-images-report.json`) | `2ff7e9add6dea291b1fe3cc67606443df797164d14132534e60e020daac2bce9` |
| Architecture log comparison (`.build/HostedLoadedImagesNov09/monitor/producer-architecture-comparison.json`) | `d3709fa5bf58ca77481e86f9e707ad937e3871f9a6b48b25a3e8f76d6e69bda2` |
| Actual executable and package-object inspection (`.build/HostedLoadedImagesNov09/products/architecture-proof.json`) | `eda1b7689c847784f209584872803caa97ec1370445718257876b2151d94665d` |
| Original producer ZIP (`.build/HostedLoadedImagesNov09/monitor/producer-evidence-13686130057.zip`) | `74b29bd14b5b54be107659f6cea6f9db617be3b8713a99d5c2ccddda19db1fbf` |
| Original scroll ZIP (`.build/HostedLoadedImagesNov09/monitor/scroll-evidence-13685832001.zip`) | `a88bba3cfcc2d629cf7968afc1b9bf4a4f0a021f7d3c0e0ceb996e0037eb0cae` |
| Original products ZIP (`.build/HostedLoadedImagesNov09/products/13684592680.zip`) | `ec8416ebd080999650c9494023686ba5f2f8102892611422d6d20a543e3b6df4` |
