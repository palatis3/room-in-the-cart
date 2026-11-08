# iOS 17 full-correction selector review

The failure is an XCTest selector mismatch. No product change is justified by this result. The app exposed `delivery.cook.fullCorrection` as a **TextView**, whereas SharedDeliveryUITests.swift:505 requested only a TextField.

Evidence from the completed result's inspected copy:

- `activities.json` and the original native log record the Review correction button tap at relative 70.71 seconds, followed by the TextField-only lookup at 71.13 seconds.
- `attachments/06860871-409B-48DD-AB35-C88D905ABD7F.txt:191`, attached at 05:37:47.010 local time immediately following that lookup, contains `TextView`, identifier `delivery.cook.fullCorrection`, frame `{{32.0, 612.0}, {311.0, 682.0}}`, and value prefix `Cook instructions ...`. The review button is still present at line 183. This establishes that the review action produced the full-correction editor; the editor was not absent.
- The product creates this editor using `TextField(..., axis: .vertical)` at SharedCookHistoryView.swift:181. Its SwiftUI type does not guarantee XCTest's exposed element type.
- The teardown failure PNG `90B62CDD-1F87-4034-A70E-53CBA73A1D5B.png` was visually reviewed. After the unsuccessful reveal helper's 16 alternating swipes it shows the top of Dated copy. It does not independently show the correction editor or establish full value equality.

`proposed-test-only.patch` changes only the query for this exact identifier and adds an explicit TextField-or-TextView assertion. It leaves `reveal(manual)`, exact `manual.value == reviewed`, disabled sharing, destination confirmation, correction contents, share flow, and sent-record assertions intact. No canonical test or product file was edited. The patch has not been executed. The existing assertion remains responsible for verifying the complete value; the retained hierarchy abbreviation cannot establish equality.

Validation should rerun the original five cases with the reviewed test-only query change and unchanged gates. This review does not pre-qualify subsequent steps or close the native/strict failure.

## Export scope and limitation

Only the inspected **copy** was supplied to xcresulttool. Scoped details and activities exported successfully. Attachment export terminated with SIGXFSZ at its 12 MiB per-file bound; the video is incomplete and must not be treated as playable evidence. The sampled 101-file bound was overshot before process termination (125 files, 13,698,200 aggregate bytes); the final inventory records this explicitly. There was no repeat or expanded export. The needed text hierarchy and failure PNG were already present and readable. Their hashes and all partial attachment sizes are in `partial-attachment-manifest.json`.

`export-receipt.json` confirms the original result bundle's full file-hash manifest was unchanged before and after all export calls. `review-receipt.json` preserves the conclusion, limitation, source hash, and exact evidence. No app, simulator, build, or test action was performed.
