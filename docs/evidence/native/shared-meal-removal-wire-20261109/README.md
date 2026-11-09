# Shared meal removal across actual clients — November 9, 2026

The native wire CI lane now requires eight Node integration cases and fifteen
exact Swift scenarios. The new case uses real Swift clients, pinned loopback
HTTPS and PostgreSQL to verify cancellation, source removal and a separate
planner’s fresh read. The original seven cases and twelve scenarios remain required.

Cancellation sends no command and leaves the authoritative state unchanged.
Removal sends an original operation plus its Codable-restored retry, advances the
shop revision once (4 to 5), and creates one tombstone. The other dinner, protected
lunch, typed meal quantities, identities, manual basket lines, quote and historical
snapshots remain intact. Direct removal of the protected lunch is rejected. The
second authorized planner sees exactly the remaining meals without basket or
budget access and sends no commands.

The full lane passes locally: 8 Node cases, 15 Swift scenarios, zero skips or
failures, in 132.90 seconds. Source/output hashes were verified, the disposable
PostgreSQL server stopped, and private attempt state was removed. Existing compiled
service outputs were reused only after all 194 source/output hashes matched their
successful build. No production code changed.

This is not complete shared F02 acceptance: cancellation is a client-operation
check, not a UI tap, and the manual basket line contains twelve **packs**, not a
typed twelve-wrap contribution. Mixed-device UI and manual/meal merge acceptance
remain open. No hosted run, migration or deployment occurred.

[Exact source and retained-original hashes](verification.json). The unique public
attempt is `.build/native-wire-results/attempt.rh7Ret/`; raw local results stay
under `.build/SharedF02RemovalNov09/native-wire-r1/`.
