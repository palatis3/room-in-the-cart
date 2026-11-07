# Evidence map — local preparation only

Start with `REPORT.md`. `evidence-map.json` contains full immutable provenance and fresh SHA-256 checks against retained original ZIPs. These files prepare a reviewable report; they do not authorize submission.

| Directory / file | Supports | Origin |
|---|---|---|
| `original-8f/metrics.json`, `metrics.csv`, `console-excerpt.json`, `original-xcresult-metrics-readback.json` | Original absence across independent result representations; five memory samples | Run 42234316869, job 127963291831, artifact 13515972039 |
| `comparator-0d33/` same files | Five actual scroll samples with the same test source and recorded toolchain/runtime | Run 42215222404, job 127888885720, artifact 13502513337 |
| `qualification-5376/` | Additional original unwrapped omission on Xcode 26.4.1 / iOS 26.4.1 | Run 42261730525, job 128057841463, artifact 13526949819 |
| Each case's `test-summary.json`, `toolchain.txt` | Exact result and device/runtime/toolchain identity | Byte-identical members of original case ZIP |
| First two cases' `build-provenance.json`; JSON map's build records | Exact Release build invocation, source commit, build-log artifact identity and hashes | Build artifacts 13514080141 / 13502161074; qualification build evidence 13526139232 |
| `UnwrappedScrollExcerpt.swift`, `ReleaseLedger500.txt` | Original manual start/swipe/stop order, five iterations, bounded fictional fixture | Git object bytes for the original candidate, identical full test file across three commits |
| First two cases' `scroll-signpost-diagnostic.json` | Supporting external UIKit summaries only | Original case ZIP; not actual collector boundaries or a replacement metric |
| JSON map's `excludedFromReproductionCount` | Why 804 setup timeout and rejected wrapper must remain separate | Existing narrow review records; raw unrelated logs not copied |

Original result ZIP digests:

- 8f: `993b790f763440eb3b61e37baf31e11a915dfafee8646d69dd84f47061e493e2`
- 0d33: `e8511c7e1defecc4d6b4a2ea1e9bc51cf3654abf831a9f5264da229b14593ccc`
- 5376: `06b89fd235aa764d0afcfc2d5d6e3f848c72ce860476d5be0db47d2a738c7db5`

Original xcresult database bytes were read from each retained ZIP into a temporary file, opened with SQLite `mode=ro`, and deleted after inspection. Only identifier/unit/sample rows are packaged. No native tooling was executed. Previously reopened/extracted xcresult database bytes may have been migrated; the original archive members, identified by hashes in the JSON map, are authoritative here. The XCTest metric database is distinct from the app's ledger database; no app persistence claim is made.

No original ZIP, opaque xcresult object, screenshot, video, raw Records artifact, app-ledger database, or credential was copied into this directory. `prepare.py` records the local evidence-only preparation; it invokes no native test, network request, hosted operation, or Git mutation. `package-manifest.json` records hashes of the prepared files. The package is a concise code example and evidence set, not a runnable minimized reproduction project.
