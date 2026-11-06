# Explicit pickup-test launch readiness

Run42301547684 reached native execution but its rendered case immediately queried a missing Shop tab and then attempted to scroll a missing container. Later retained hierarchy and failure screenshot show the normal Shop screen. This supports a launch/accessibility-readiness race; its underlying cause is not established.

The local four-line test change explicitly requires Shop to exist within10seconds before pickup navigation. It does not alter the app, generic scrolling, fixture, measured loops, five iterations, twenty samples, persistence checks, performance limits or workflow budgets. This setup condition can add up to10seconds per helper call (twice for rendered, once for scroll), outside measured samples. Cold launch measurement remains unchanged.

Root verified the original archive digest, independently viewed the failure screenshot, checked that removing these four lines produces byte-identical f117 source, and type-checked the whole RELEASE test file on local Xcode27.1 with zero diagnostics. Independent review supports this narrow change. This is not native validation, a measured performance pass, or a fix for earlier missing scroll metrics. The original failed run is retained. No new run was dispatched for this change at this checkpoint.

Apple documents that `waitForExistence(timeout:)` returns false when the element remains absent through the bounded wait. The new assertion uses that documented public API; this does not establish a cause for delayed tree availability. [Apple API reference](https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence(timeout:)) (checked November6,2026).
