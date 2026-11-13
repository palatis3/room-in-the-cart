# Bounded UI09 process-discovery recovery

The preceding hosted diagnostic passed all eight native cases and strict checks but lost its observer on the first two-second process query before native launch. The collector now records failed observations, preserves known identities without treating a failed query as an empty snapshot, and permits recovery within a total three-failure budget. Target-window loss remains permanently ambiguous; source identity, sealing and coverage gates are unchanged.

A recovered empty pre-target snapshot can establish a new baseline only after complete buffered case markers are read. Partial markers, pending log bytes and a nonempty owned-app snapshot cannot clear the gap. Identity/parser and probe/lsof failures remain separate fatal errors. Thread-start handshake is explicitly distinct from successful process discovery. No native test retry, QoS/log suppression, timeout increase or app diagnostic change was introduced.

All50 offline checks passed (22 boundaries,14 setup,14 discovery), plus workflow validation. Root reviewed the delta, verified the frozen files, applied exactly three files and pushed isolated diagnostic commit7f3d3ce. [One hosted successor](https://github.com/palatis3/room-in-the-cart/actions/runs/42502133362) is active. Build and owned simulator boot passed; the native, strict and capture outcomes are not yet known. Main PR1 was not pushed by this diagnostic action.

The copied validation scripts and payload preserve the reviewed offline reproduction. The known keyboard-event cap and other coverage limitations still fail complete-capture acceptance; a sealed trace is not automatically complete. This observer correction does not establish the cause or repair of the original animation timeout.
