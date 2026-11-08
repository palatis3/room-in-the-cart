# Shared cook-copy confirmation still fails in CI

Published source `fe3e143` fixture job128838829640 completed four passing cases and one failure. `SharedDeliveryUITests/testShopperSavesDatedCookCopyAndReopensRecipientSendRecord` failed at119.868seconds: after tapping the inner switch, its identified parent still reported0 rather than1 at line544. Root reviewed the actual failure screenshot: the confirmation row and switch are fully visible, the switch is off, the prior sent version is1, and no keyboard covers the control. That establishes the failed state, not whether the tap reached the binding or later state reset it.

The original artifact13632857564 and job log remain private under `.build/CIFe3e143Nov08`. A preserved archived-bundle clone was queried once for its console log; xcresulttool reported `No console log available`. No repeat query or native rerun followed. The separately exported failure screenshot succeeded and the original bundle remained unchanged. Missing console output is not proof that the diagnostic setter was never invoked.

The strict runtime-warning inventory is also unavailable: an internal priority-inversion activity lacks the required Complete Issue Description attachment. The failing confirmation and unresolved speech/runtime-warning evidence remain separate open issues. No gate was waived, no retry added, and no control or test interaction changed on this evidence alone.

The same cohort's Core workflow is terminal: ordinary UI02–10 passed, UI01 retains the previously recorded English animation timeout, and its aggregate gate failed consequently. Other fixture jobs were still running at this checkpoint. The scroll-performance metric-count failure remains open.
