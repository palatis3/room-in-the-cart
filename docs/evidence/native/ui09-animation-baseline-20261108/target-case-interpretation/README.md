The closed PID39312 trace is a passing instrumented Store-Done baseline. The target second case passed in130.127seconds. It did not reproduce the original animation-idle stall, identify its cause, or establish a repair. The full eight-case run was still active during this analysis; no xcresult was inspected.

Binding is to the exact collected file hash e36d3b6059450641b4789a456f84b1c746774d919a632971655821516012e7ff (114,620bytes/33rows), verified against root's collection receipt. The monitor observed the exact owned-device debug executable PID39312 inside the selected case window, then observed its absence after the case passed. Root collected only the closed file after those events and the sink footer. Candidate source manifest006479… is the passed-build source; its Store-only, once-per-process Done wrapper supplies the boundary identity. The earlier Done at test t19.02 belongs to another editor and is not this probe.

Selected native log metadata, preserved with byte offsets in native-boundary.json: Store tap t47.96; target Done tap52.21, synthesis52.39, post-event idle wait52.69; Branch lookup53.03 and tap54.39. The case continues instead of a minute-long idle wait. Probe timestamps are relative to the Store-Done closure and are not the native log's test-relative clock. Sampled monitor UTC times/log buffering and file birth time cannot supply an exact shared timestamp origin.

Measured overhead across14 inventories (p95 uses linear R7 interpolation):

| Measurement | Median ms | p95 ms | Max ms | Total ms |
|---|---:|---:|---:|---:|
| Public layer inventory |1.566|2.613|3.122|23.978|
| Inventory plus derived sample encoding |2.174|3.576|4.026|33.472|

Sample-encoding times are reconstructed from cumulative counters; their total is9.494ms. Separate callback/dismiss/footer encoding and all dispatch/observer costs are outside that total. Pre-dismiss setup+inventory cost3.153ms; original dismissal closure0.028ms. Footer reports maximum main-thread encoding0.995ms and background write1.570ms. No sample/cumulative stop limit fired. Timing perturbation remains possible; these measurements do not prove an equivalent uninstrumented schedule.

All14 inventories completed their bounded traversal:346–560 layers, two windows, zero traversal/key/child/interesting-record truncations. Sink reported zero dropped records and windowComplete at64.400seconds. Samples were delayed beyond requested offsets, including the one-second sample at1.156 and16-second sample at16.956; lateness is scheduling delay, not measured inventory CPU. Keyboard callbacks reached their separate16-event cap at12.995seconds; later callback silence must not be interpreted as absence of keyboard activity.

The initial dismissal sequence:

- Before Done:16 retained animation keys; UITextField/UIFieldEditor responders present; scroll bottom adjusted inset379.
- By0.042seconds: no enumerated responders; bottom inset83;27 keys. Twelve new keys belong to UIKeyboardItemContainerView(layer4), _UIRemoteKeyboardPlaceholderView(6), UIKeyboardDockView(7) and _UIScrollViewScrollIndicator(133). They are spring animations on position/bounds.size, duration0.3833, speed1, no repeat, removed-on-completion true. Layer4 position and layer133 position/bounds have model/presentation differences during these samples. The other spring-bearing records need not have a geometric difference at every sample.
- didHide arrives at0.440seconds, with the keyboard end frame outside the402×874 viewport. At0.534,1.156 and2.123seconds those twelve transient keys are no longer reported;15 keys remain and responders remain absent. The next keyboard-frame event toward the visible keyboard is2.451seconds, consistent with the subsequent Branch interaction. That bounds the clean post-hide/pre-next-focus interval.

The15 remaining keys occur on three pre-existing UIKit layers:30 and99 are runtime UISDFElementView implementations (seven keys each);35 is the _UILiquidLensView DestOutView implementation (one key). All animation records report kind/property `other`, speed1, repeatCount/repeatDuration0, autoreverses false and removed-on-completion false. Their beginTime values remain959698.2325758752 for30/35 and959740.0777468752 for99, already present before Done. Duration−999999 is the probe's nonfinite sentinel; it does not identify infinity versus NaN, an actual negative duration, or an active idle blocker.

Their complete records are identical before Done and at all three post-hide samples. Stable model→presentation differences persist: layer30 bounds0×0→274×62 and position(0,0)→(201,31); layer35 position(47,27)→(51,31); layer99 bounds0×0→44×44 and position(0,0)→(38,22). These stable differences and retained keys coexist with successful progression. They are not sufficient evidence of a stuck animation. A separate baseline UIView(layer330) opacity keyframe, duration1 with a very large repeat count, disappears from interesting records by0.042; its generic view type does not prove cursor ownership.

Samples from4.365seconds onward overlap later field editing and navigation. They cannot be described as a continuously stuck Store-Done animation. Public app-layer inventory also cannot expose XCTest's private idle bookkeeping, SwiftUI transaction-completion tokens or all remote keyboard state. The useful result is the observed normal dismissal pattern and evidence that persistent public keys/model–presentation differences alone would be a poor failure criterion. The original UI09 cause remains unresolved.
