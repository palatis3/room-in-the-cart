# Retained Close tap: coordinate repair is not established

Both authorized objects exported successfully from the inspected copy under a 4 MiB per-file/30-second bound. No fallback/larger export, video, UI action, or canonical edit occurred. `export-receipt.json` records exact attachment UUIDs, payload IDs, timestamps, commands, byte sizes, SHA-256 values, and unchanged original bundle manifest.

- UI Snapshot UUID `7CB7FE18-3698-4F30-A5EC-6D482593AF05`, timestamp 1794135496.210: 1,367 bytes. Passive plist decoding yields only the Room in the Cart application root, frame `{{0,0},{402,874}}`, enabled=true, no children. This is **not** a snapshot of Close; the enabled flag cannot be attributed to Close, and no button bounds/hittability are retained.
- Synthesized Event UUID `66BE50B2-371C-4ECE-85C0-15F74C2A893D`, timestamp 1794135496.518: 1,881 bytes. It records the named `tap`, PID 97211, two pointer events at `(364,110)` with offsets 0 and 0.05 seconds, in a 402×874-point parent window. Encoded target-frame fields are all zero; they are not usable Close bounds. This establishes the recorded event coordinates, not successful OS delivery or activation.

The final failure PNG was captured 19.403 seconds after the event attachment. Its visible Close X is approximately at that upper-right location. This visual comparison supplies no evidence for an off-center coordinate correction, but it cannot rule out a transient frame/readiness change at tap time. Neither object shows whether the sheet briefly disappeared and reappeared, whether the event reached the remote view, or whether the app's completion callback ran.

The prior conclusion remains: the test proceeded while the system share sheet remained present, and a strict dismissal postcondition would report the true failure boundary. No product repair, coordinate-tap replacement, repeated tap, or increased readiness allowance is justified. Further discrimination requires a contemporaneous Close-specific frame/state observation and post-tap disappearance/callback evidence; these retained objects do not contain it.

`close-snapshot.decoded.json`, `close-event.decoded.json`, and `passive-review.json` were created only with plistlib and explicit UID-table reads. No archived objects were instantiated or unpickled.
