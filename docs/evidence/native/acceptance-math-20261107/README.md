# Exact checkout-deferral and usable-food examples

Two Foundation2.1 S05 examples are now permanent shared calculation vectors, executed by both Swift and TypeScript. Starting from $34.80 protected goods, $4.60 coffee and $1.50 salsa, deferring coffee leaves $36.30 and keeps the $4.95 fee waived. Deferring both leaves a $34.80 eligible subtotal, restores the fee and costs $39.75. Both compare with the same original $40.90 checkout; only the first is within a $38 cap. This prevents treating each removal as an independent saving while forgetting the fee threshold.

The existing S08 pickup test now follows its six-usable-wrap scenario with the specified correction to seven. Two protected lunches stay allocated, tacos increase from four to five, and quesadillas remain short. The eight-delivered fact stays unchanged. Replaying the correction adds nothing; both original and corrected observations and the allocation survive serialization.

Root built and ran all171CoreDomain cases:171pass,0skip,0failure; the compiled inventory exactly matches the reviewed inventory under the repository’s strict verifier. The independently implemented service checkout suite passes13/13, including both new vectors. Source hashes remained unchanged through verification. No production calculation or UI code changed, and no additional CI job was added.

This fills exact calculation/replay/serialization coverage for S05.01/S05.02/S08.02. It does not prove the corresponding native screens, physical devices, deployed service or entire screen contracts. The existing published8d1a79b cohort does not include these new examples. Logs, manifests and the exact patch are retained here; `freeze.json` binds the evidence.
