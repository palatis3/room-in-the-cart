# Earlier dinner editor stalls before the supply candidate

R2 gives the supply sheet's Done label a minimum44×44 frame and rectangular
content shape. Its incremental build and compiled-app check passed; build time
was23.160seconds. The original English journey then encountered repeated
animation waits before opening that sheet. The first wait follows Done on the
unchanged dinner editor's Amount, optional field (tap33.11s, missing-completion
message93.60s). The subsequent scroll also waits. This extends the observed
failure locations; it does not identify the private animation owner.

Root stopped this diagnostic early with SIGINT to the verified owned xcodebuild
process group because repeated waits already violated its zero-idle qualification
gate. Native exit75 and strict exit1 are retained. Four idle messages were recorded.
This is an **interrupted failure**, not a completed720-second reproduction. Xcode
emitted an internal assertion during cancellation; no app crash is inferred.
Its exported zero-second case duration is not a usable duration measurement.

The new supply target was not exercised: there are no required supply captures,
no new target-size proof and no approval/restart result. Original source/products,
result/log/receipt and prior R1 failure evidence remain verified unchanged.
Next work must also address the earlier dinner editor's keyboard dismissal.
No timeout, target-size or strict-check requirement was relaxed.
