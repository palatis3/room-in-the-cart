# Standalone XCTest report-window diagnostic

Apply `test-overlay.patch` only to the exact0d5 ReleasePerformanceUITests source (SHA256 c7954233968072b97fd5845d5c28877c9251495cfee33675169a960839d2625f), in a separate diagnostic checkout. It appends a standalone witness after the unchanged built-in metrics and emits one post-measure JSON attachment. No fabricated metric/sample is returned. Existing public-call and rejected wrapper diagnostics are different experiments.

The Swift fragments are the source for the patch, not additional app-target files. `main.swift` is the Foundation-only recorder check harness; `test_correlate.py` exercises the observation projection. The correlation CLI accepts a witness JSON, the previously reviewed schema2 endpoint receipt and an output path; it hashes both inputs. Bind them to the same original result, source, product, device and selector separately. Never use its output as an acceptance metric or infer a warm-up ordinal.

Local Xcode27.1 compatibility passes; hosted26.3 remains unqualified. See ../../docs/evidence/native/scroll-report-window-local-20261106/README.md for exact result/limits. Do not dispatch blindly while the original cohort remains active. This diagnostic does not enter production code or replace the required scroll duration.
