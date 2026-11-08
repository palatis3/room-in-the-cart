# Cook confirmation diagnostic transport

The existing exact-scope, Debug-fixture-only trace now also writes unified-log
notices under a dedicated subsystem/category. It records only diagnostic state
identity, event name, PID, uptime and booleans; no recipient, wording or product
identifiers. The original stdout trace and every UI action/assertion remain.

The original complete cook-copy journey passed locally in128.11seconds,
native0/strict0, with zero recorded runtime warnings/restarts. Root reviewed the
saved-history, dated-copy and correction-editor captures. A bounded unified-log
query recovered129 schema-checked events from appPID44572. Every event timestamp
falls inside the native run, and the PID matches the original XCTest app
termination. One setter changes false→true, returns true, and is followed by a
false→true state observation. A later explicit send-history check invalidates
the review. The raw214,867-byte log is private and hash-pinned; its validated
diagnostic fields and analysis are retained here.

This proves trace transport in a passing local run. It does not reproduce or
explain the hosted switch-off failure, prove exhaustive delivery, or establish
that logging cannot change timing. The separate missing speech-warning
description remains unresolved.

Unsigned Release and built-app checks pass. The three diagnostic markers are
absent from the main Release executable in UTF8 and UTF16LE searches. Workflow
validation also passes. The fixture workflow now collects the scoped log in its
own bounded step before simulator cleanup; raw Records-media output remains
excluded. Hosted collection is the next qualification step.

Source manifest:8d0eb48f5f54f1ac22b43a01966509d9637b34ec88d9f13a06d3a145967f5d1a.
Private originals, inspected clone and preserved products remain under
`.build/CookDestinationLogNov08/`.

Logging API reference: [Apple unified logging](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code).
