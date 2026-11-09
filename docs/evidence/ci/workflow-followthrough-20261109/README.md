# Workflow failure retention — November 9, 2026

Core and fixture builds now retain compiler stdout/stderr and a small receipt
binding the checkout, run/attempt, configuration/profile and Xcode. Compiler
errors still fail through `tee`; uploads are attempted even after build failure.
The new diagnostic uploads are best effort, warn if absent and retain two files
for seven days. Existing gates, build arguments, test coverage and five slots
are unchanged.

Native wire invocations use unique attempt directories. Each Swift scenario
retains bounded output, stream hashes and structured failure metadata. Later
attempts cannot replace previous evidence. A failed local database/journal/TLS
fixture remains owner-only outside upload paths, with private custody metadata;
a successful attempt removes it. Failed shutdown cannot delete live state.
Private state on a hosted runner lasts only for that runner's lifetime.

Validation: all 449 Python source-contract checks pass, including five shell
failure/custody controls and three build-evidence methods covering four profiles.
The Node output-control case checks overflow, exact result identity, collisions,
environment omission and simultaneous native/evidence failures. Workflow validation
passes all 17 queue definitions. A real revised harness run passes the original
seven Node cases and twelve exact Swift scenarios in 134.77 seconds. All 12 scenario
outputs/hashes were verified; sources remained unchanged and private state was
removed after PostgreSQL stopped. This is a local result, not a measured CI speedup.

Separately, the tiny host Logging collector now has readable proof of two boundary
events and three ordered positive intervals. Ten parser controls and independent
root review pass. Helper, tracer and export exited normally; originals remained
unchanged. This qualifies host capture only. A small simulator control is still
needed before another app tracing attempt; hosted missing metrics and minimum-iOS
acceptance remain unresolved.

[Exact source and retained-original hashes](verification.json). Raw logs and
receipts remain under `.build/WorkflowFollowthroughNov09/`, the referenced unique
wire attempt, and `.build/HostSignpostControlNov09/`. No large raw archives were
added to Git. No hosted run, merge, staging deployment or baseline approval occurred.
