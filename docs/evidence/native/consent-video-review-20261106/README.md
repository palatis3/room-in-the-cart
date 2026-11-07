# Original consent failure: video observation

Root decoded the retained Measurement test recording from exact804fixture artifact13534503902 and inspected the full requested23-second frame plus the [contact sheet](contact-sheet.png). The switch appears off in all inspected decoded frames where it is visible. No visual flip was observed.

The video is27.183seconds long. There are51requests at0.2-second intervals from16through26seconds, but only17distinct decoded timestamps: the recording holds frames between updates. The contact-sheet labels show **actual decoded video timestamps**, not requested timestamps or XCTest action times. This does not rule out an unrecorded short transition or prove that the setter was never called. No UIKit hit-target inference is made.

The source image is1206×2622pixels on a402-point-wide device. Crops cover x295–395,y600–715points around the switch. Only this fictional Measurement fixture video was accessed; no Records media or Android sign-in screen was read. [Hashes, exact times and limitations](verification.json) · [Frame mapping](frames.json).

The prepared opt-in diagnostic remains the next observation step. This visual review does not establish a product fix, change any test, or replace the original failed assertion.
