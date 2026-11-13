# Current-OS dark follow-up: share dismissal remains unresolved

**The system share sheet is still visible at failure. This evidence does not support a recipient selector/scroll fix or locate a product defect.**

The recorded `header.closeButton` tap occurred at 35.56 seconds after the existing readiness predicate passed. At 37.26 seconds XCTest found `delivery.cook.recipient` as a TextField, but the field was not hittable. The reveal helper then issued 16 swipes and failed. The synchronous teardown screenshot, `screens/C4D0D7B6-74B4-4997-B733-6111BA5F8DDD.png` (timestamp 1794135515.921), visibly contains a fully populated system share sheet, including its upper-right Close X, Reminders/app/More destinations, Copy, and Save to Files. This explains why proceeding to scroll for an underlying recipient field was invalid.

The prior `Shared dated cook copy` screenshot (`00617AED-DAD3-46D5-8DA3-03A579F312CC.png`) shows the expected Dated copy screen before opening Share. Both exported textual hierarchies predate the share presentation: the later one, `hierarchies/8C182AC9-0EF6-4B16-9231-D91AA3175A02.txt`, is timestamped 1794135492.091 during the pre-share savedShare reveal. They cannot establish the Close control's enabled state, frame/tap location, event delivery, post-tap disappearance, or a later re-presentation. Do not interpret the action title as proof of effective dismissal or the final screen as proof the sheet never briefly disappeared.

Current source directly presents UIActivityViewController via PickupActivitySheet and clears the sharing item in its completion callback. No defect in that product boundary is identified by these observations. Likewise, the passing iOS 17 journey and earlier runs do not prove this event was harmless or unrelated to the surface changes.

## Narrow next step

`proposed-dismissal-boundary-only.patch` adds an explicit share-disappeared postcondition after each of this journey's two Close taps. It retains the existing 15-second readiness bound, performs exactly one tap, and adds a separate bounded 15-second disappearance assertion with screenshot-before-hierarchy evidence if it fails. It does not retry dismissal, change scrolling, switch the recipient query, relax any business assertion, or change case allowances. This is an assertion/evidence improvement, **not a proposed product repair or demonstrated flaky-test fix**. It passed `git apply --check` but was not applied or executed.

The discriminating evidence still missing is the Close state/frame and actual tap point immediately around the tap, followed by post-tap screen/hierarchy and disappearance. The activities metadata identifies narrowly retained UI Snapshot and Synthesized Event objects around that tap, but these are outside this review's TXT/PNG-only export authorization. No such binary object or video was exported. A separately approved bounded inspection could use those objects before deciding whether any target-placement change is justified.

## Preservation and bounds

`export_bounded.py` obtains the actual nodeIdentifierURL from tests.json and exports scoped activities plus filename-filtered `*.txt`, `*.debug` (rendered as text), and `*.png` attachments only. All four calls succeeded under 8 MiB per-file, 32 MiB aggregate, 60-file and 45-second per-call bounds. No video or unfiltered export was performed. `export-receipt.json` records commands, hashes, and that the complete original result manifest remained unchanged. No app/simulator/build/test action, product edit, or canonical test edit occurred. `review-receipt.json` distinguishes the established screen state from the unresolved cause.
