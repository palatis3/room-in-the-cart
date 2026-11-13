# Candidate 0d5bb1b security evidence

The original security workflow 42316648580 attempt 1 succeeded. Its pinned analyses report 87 JavaScript/TypeScript rules and 17 Actions rules, both with zero findings. Dependency review passed. The analyzed PR merge 525d68a has the same tree as candidate 0d5bb1b. API-returned SARIF lacks complete input coverage and invocation diagnostics; logged extracted paths are observations rather than exhaustive semantic coverage.

Swift CodeQL in core workflow 42316648565, job 128230769738, also completed successfully: 27 rules, zero findings. All 254 expected runtime inputs are present (253 tracked inputs plus generated asset symbols). Root independently matched 258 archived repository files, including package manifests, to the exact candidate Git objects. Eleven compiler diagnostics match the preceding 804 candidate; 292 unresolved AST nodes out of 1,906,154 remain explicitly recorded. Zero findings is not proof of vulnerability absence.

Original Swift artifact 13553643194 has SHA256 `0b6c6db7b05f231a7f8b45d9e2a91b3bf01ae3595e57c935f601fff6ed578e2a`. The default nested archive ratio guard refused a 1,048,592-byte database page compressed to 1,046 bytes. That refusal remains retained and the limit is unchanged. A separate bounded read inspected only exact database metadata and the source archive, checking member identity, size, CRC and compression bounds. The metadata declares finalised: true; the database payload, including the refused page, remains unread. This establishes the stated source-input evidence, not acceptance of the complete database archive.

Root rehashed all 15 frozen Swift evidence files and all 13 frozen security-workflow files with no mismatch. Compact receipts and audit scripts are preserved here; originals and SARIF stay under `.build/CIResearch20261106/candidate-0d5bb1b/`. The original security verification's sentence saying Swift was pending reflects its earlier collection time; the separate terminal Swift evidence supersedes that status only.

The other UI, fixture and performance jobs are separate gates. These results do not establish release readiness or erase the current UI01/UI04 failures.
