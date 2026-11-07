# Quote switch boundary diagnostic

The published1080 ui-04 quote case fails when its first charges switch remains off after the original trailing tap. Root and Astra viewed the exact failure PNG: the switch is visible and off, with no keyboard. The retained public AX snapshot is empty; it cannot establish event-time geometry or tap delivery. Nine animation-idle notices precede the terminal assertion. No binding, keyboard or animation cause is established.

Installed test-only instrumentation captures public control/frame/enabled/hittable/value, navigation/tab/keyboard/Done state, intended point and one screenshot immediately before and after the original first charges-switch action. The intended point is not evidence of delivered touch coordinates. Four bounded attachments apply only to this synthetic quote boundary. Original queries, coordinate, conditional tap, assertions, scroll limits and timeouts are unchanged; no retry is added.

Whole-file Swift5 DEBUG iOS17 simulator typecheck exits0 with an empty log. The diagnostic has not executed natively or in hosted CI. Sequential observations may change timing; passing with instrumentation would not prove a product fix. Exact source hashes and the retained case-proof rehash are recorded. The original failure and archive remain preserved separately; no Records media was accessed.
